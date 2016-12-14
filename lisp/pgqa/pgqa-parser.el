;; Copyright (C) 2016 Antonin Houska
;;
;; This file is part of PGQA.
;;
;; PGQA is free software: you can redistribute it and/or modify it under the
;; terms of the GNU General Public License as published by the Free Software
;; Foundation, either version 3 of the License, or (at your option) any later
;; version.

;; PGQA is distributed in the hope that it will be useful, but WITHOUT ANY
;; WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
;; FOR A PARTICULAR PURPOSE. See the GNU General Public License for more
;; details.

;; You should have received a copy of the GNU General Public License qalong
;; with PGQA. If not, see <http://www.gnu.org/licenses/>.

(require 'semantic)
(require 'semantic/lex)
(require 'semantic/wisent/comp)

(setq wisent-parse-verbose-flag t)

;; TODO Try defvar at top level instead of doing the setup each time.
(define-lex-regex-analyzer semantic-lex-error
  "Detect any unrecognized character. Must be the last analyzer tried."
  "."
  ;; TODO Get both character and line number from the parser state.
  (error "Unrecognized character"))

;; Instead of semantic-lex-punctuation analyzer we use
;; semantic-lex-punctuation-multi, to cover multi-character operators.
;;
;; pgqa-punctuation-operators-multi is the list of mulit-character operators
;; consisting of punctuation characters. It's needed by this special analyzer.
(defvar pgqa-punctuation-operators-multi nil)

(define-lex-regex-analyzer semantic-lex-punctuation-multi
  "Detect and create punctuation token, which possibly consists of multiple
characters."
  "\\(\\s.\\|\\s$\\|\\s'\\)" 'punctuation
  ;; (print (format "%s, %s" (match-beginning 0) (match-end 0)))
  ;; (print (point))
  (let ((beginning (match-beginning 0))
	(end (match-end 0))
	(width-max 0))
    ;; Find the longest matching multi-character operator.
    ;;
    ;; TODO Consider sorting of pgqa-punctuation-operators-multi by length
    ;; during initialization and terminating the search when the first match
    ;; is found.
    (dolist (op pgqa-punctuation-operators-multi)
      (let ((width (string-width op)))
	(if (and (looking-at op) (> width width-max))
	    (setq width-max width))))

    (if (> width-max 1)
	(setq end (+ end (1- width-max))))

    (semantic-lex-push-token
     (semantic-lex-token
      'punctuation beginning end))))

;; TODO Add a function to kill "orphan query buffers". User can create them by
;; killing the root buffer, after having removed all query buffer links from
;; it.

(defvar pgqa-automaton nil)

;; If non-nil, pgqa-parse always calls pgqa-init-parser. This is useful during
;; development, when the grammar is changed rather often. nil implies that the
;; parser is only initialized only.
(defvar pgqa-parser-always-init nil)

;; Keywords are stored in a hash table, so that it's easy for the parser to
;; check whether a token is a keyword.
(defvar pgqa-keyword-hash nil)

;; Likewise, store other terminal strings in a hash, to decide quickly if
;; token should be considered a terminal.
;;
;; TODO Consider using a single hash for all terminals.
;;
;; TODO A function that performs all the operator-related initializations, so
;; that it's easy to reload custom operators from PG.
(defvar pgqa-terminal-hash nil)

;; Special values of precedence or those referenced multiple times throughout
;; the code.
(defconst pgqa-precedence-comma -1)
(defconst pgqa-precedence-plus 4)
(defconst pgqa-precedence-times 5)
(defconst pgqa-precedence-uminus 6)

;; As the grammar definition does not accept terminals in the form of string,
;; a symbol must exist to represent each terminal. We can't use hard-wired
;; symbols in general because PostgreSQL allows user to define custom
;; operators. Therefore we generate symbols for operators by adding numeric
;; prefix to per-group symbol.
;;
;; Each operator group is specific by the "base" symbol, precedence and the
;; actual list of operators. If associativity differs while precedence is
;; equal, use separate groups too.
;;
;; Note that pgqa-precedence-uminus is not used by any group.
(defvar pgqa-operator-group-1
  ;; ?* isn't there on purpose. It has to be treated separate because of its
  ;; use as a wildcard. See all references to this group.
  '(OPGROUP-1 pgqa-precedence-times "/"))

(defvar pgqa-operator-group-2
  '(OPGROUP-2 4 ">" "<" "=" "<=" ">=" "<>"))

(defvar pgqa-operator-group-3
  '(OPGROUP-3 3 "IS" "ISNULL" "NOTNULL"))

(defvar pgqa-operator-group-4
  '(OPGROUP-4 2 "NOT"))

(defvar pgqa-operator-group-5
  '(OPGROUP-5 1 "AND"))

(defvar pgqa-operator-group-6
  '(OPGROUP-6 0 "OR"))

(defvar pgqa-operator-groups
  (list pgqa-operator-group-1 pgqa-operator-group-2 pgqa-operator-group-3
	pgqa-operator-group-4 pgqa-operator-group-5 pgqa-operator-group-6))

;; Single-character terminals not contained explicitly in any group above.
;; These can also be used as a symbol in the grammar definition.
(defvar pgqa-terminals-non-grouped
  '(?\; ?. ?, ?* ?+ ?- ?) ?( ))

;; Create gramar rule for binary operator.
;;
;; XXX The function is actually used for operators having more than 2
;; arguments (AND / OR) but I have no idea about suitable function name.
(defun pgqa-create-binop-expr-rule (op opsym prec)
  (setq pattern
	(list 'expr opsym 'expr))
  (setq action
	(list 'make-instance
	      (quote 'pgqa-operator)
	      :op op :args '(list $1 $3)
	      :prec prec
	      :region '(pgqa-union-regions $region1 $1
					   $region3 $3)))
  (list pattern action))

;; Create gramar rule for unary prefix operator.
;;
;; `prec-nonterm' is precedence of the non-terminal (expression) for which
;; we're constructing the rule. In contrast, `prec' is precedence used merely
;; to print the query. This is only to handle the special case of unary plus
;; and minus operators. (Nothing like that is needed for postfix operators, as
;; these - being all the user operators - have precedence different from
;; possibly confilicting core operators.)
(defun pgqa-create-prefix-unop-expr-rule
    (op opsym prec &optional prec-nonterm)
  (setq pattern
	(list opsym 'expr))
  (setq action
	(list 'make-instance
	      (quote 'pgqa-operator)
	      :op op :args '(list $2)
	      :prec prec
	      :region '(pgqa-union-regions $region1 $1
					   $region2 $2)))
  (if prec-nonterm
      (list pattern prec-nonterm action)
    (list pattern action)))

;; Likewise, create a rule for postfix operator.
(defun pgqa-create-postfix-unop-expr-rule
    (op opsym prec)
  (setq pattern
	(list 'expr opsym))
  (setq action
	(list 'make-instance
	      (quote 'pgqa-operator)
	      :op op :args '(list $1)
	      :prec prec
	      :postfix t
	      :region '(pgqa-union-regions $region1 $1
					   $region2 $2)))
  (list pattern action))

;; Create rules for given operator group and add them to the list which is
;; eventually used to generate the grammar.
(defun pgqa-create-operator-rules (group result op-hash create-func)
  (let* ((gsym (car group))
	 (rest (cdr group))
	 (prec (car rest))
	 (ops (cdr rest)))
    (dolist (op ops)
      (let ((sym-str)
	    (rule))
	;; Use the same symbols that pgqa-terminal-hash should already
	;; contain.
	(setq sym (gethash op op-hash))
	(setq rule (funcall create-func op sym prec))
	(push rule result)))
    )
  result
  )

;; Construct a list of operator symbols for given group. We retrieve them from
;; the hash table because we've constructed most of the symbols
;; programmatically and want them to match wherever comparison takes place.
(defun pgqa-operator-group-symbols (group op-hash)
  (let* ((gsym (car group))
	 (rest (cdr group))
	 (prec (car rest))
	 (ops (cdr rest))
	 (result))
    (dolist (op ops result)
      (push (gethash op op-hash) result))
    result))

;; Keywords in plain format. New keywords should be added here.
;;
;; TODO Consider if strings are safer than symbols, in terms of conflict with
;; other elisp modules.
(defvar pgqa-keyword-symbols '(AS BY DELETE FROM FULL GROUP INNER
  INSERT INTO JOIN LATERAL LEFT LIMIT ON ORDER OUTER RIGHT UPDATE
  RETURNING SELECT SET VALUES WHERE WITH))

(defvar-local pgqa-query-tree nil
  "Tree of the last successfully parsed query.")

(defvar-local pgqa-parse-error nil
  "Has the last parsing ended up with an error?")

(defun pgqa-get-nonterm-region-pos(region node start)
  "Retrieve start or end position from $regionN Wisent variable or from node,
whichever is available."
  (let ((vec))
    (if region
	(setq vec (car region))
      (setq vec (oref node region)))
    (elt vec (if start 0 1))))


;; Wisent only seems to support the $region variable for simple non-terminals
;; (is the problem that it can't union multiple values of $region ?) so we
;; need to derive them where necessary. This function does so by retrieving
;; the start position from the first region and the end position from the
;; last one.
(defun pgqa-union-regions(region-1 node-1 region-2 node-2)
  (vector
   (pgqa-get-nonterm-region-pos region-1 node-1 t)
   (pgqa-get-nonterm-region-pos region-2 node-2 nil)))

;; Get the region in list format from a single nonterm.
(defun pgqa-get-nonterm-region(region node)
  (list (pgqa-get-nonterm-region-pos region node t)
	(pgqa-get-nonterm-region-pos region node nil)))

(defun pgqa-init-parser ()
  (setq pgqa-keyword-hash (makehash 'equal))
  (let ((result pgqa-keyword-hash))
    (dolist (i pgqa-keyword-symbols result)
      ;; String is the key so we can lookup token values here, symbol is the
      ;; value because parser expects symbols.
      (puthash (format "%s" i) i result)
      )
    )

  ;; Initialize pgqa-punctuation-operators-multi, ie collect all
  ;; multi-character operators consisting of punctuation characters (we assume
  ;; that all chars are punctuation or none, so it's o.k. to test only the
  ;; first character).
  (dolist (g pgqa-operator-groups)
    (let ((ops (cdr (cdr g))))
      (dolist (op ops)
	(if (and
	     (> (string-width op) 1)
	     (string-match "\\s." op))
	    (push op pgqa-punctuation-operators-multi)))))

  (define-lex
    simple-lex
    "Lexer to provide input for SQL parser."
    semantic-lex-ignore-whitespace
    semantic-lex-ignore-newline
    semantic-lex-ignore-comments
    semantic-lex-open-paren
    semantic-lex-close-paren
    semantic-lex-number
    semantic-lex-newline
    semantic-lex-whitespace
    semantic-lex-symbol-or-keyword
    semantic-lex-string
    semantic-lex-punctuation-multi
    semantic-lex-error)

  (let ((grammar-list)
	(automaton)
	(nonterm-assoc)
	(rule-sublist-1)
	(rule-sublist-2)
	(terminals)
	(expr-rules)
	(nonterm-expr))

    (setq terminals (append pgqa-keyword-symbols pgqa-terminals-non-grouped
			    '(NUMBER STRING SYMBOL)))

    ;; Initialize the hash in which tokenizer will look-up the terminal
    ;; symbols.
    (setq pgqa-terminal-hash (makehash 'equal))
    (let ((result pgqa-terminal-hash))
      ;; Process the operators by groups.
      (dolist (group pgqa-operator-groups result)
	;; Omit precedence, not needed here.
	(let ((gsym (car group))
	      (ops (cdr (cdr group)))
	      (i 0)
	      (sym-str)
	      (sym))
	  (dolist (op ops result)
	    ;; Create unique symbol per operator.
	    (setq sym-str (format "%s_%d" (symbol-name gsym) i))
	    (setq sym (make-symbol sym-str))
	    (puthash op sym result)
	    ;; Also add it to the list of terminals.
	    (push sym terminals)
	    (setq i (1+ i)))))

      ;; Add characters not contained in any group.
      (dolist (i pgqa-terminals-non-grouped result)
	(puthash (char-to-string i) i result))
      )

    ;; Terminal associativity & precedence
    (setq nonterm-assoc
	  (list
	   '(left ?\;)
	   '(left ?,)

	   (append '(left)
		   (pgqa-operator-group-symbols
		    ;; OR
		    pgqa-operator-group-6 pgqa-terminal-hash))

	   (append '(left)
		   ;; AND
		   (pgqa-operator-group-symbols
		    pgqa-operator-group-5 pgqa-terminal-hash))

	   (append '(right)
		   ;; NOT
		   (pgqa-operator-group-symbols
		    pgqa-operator-group-4 pgqa-terminal-hash))

	   (append '(nonassoc)
		   ;; IS, ISNULL, NOTNULL
		   (pgqa-operator-group-symbols
		    pgqa-operator-group-3 pgqa-terminal-hash))

	   (append '(nonassoc)
		   ;; >, <, etc.
		   (pgqa-operator-group-symbols
		    pgqa-operator-group-2 pgqa-terminal-hash))

	   '(left ?+ ?-)

	   (append '(left ?*)
		   ;; /
		   (pgqa-operator-group-symbols
		    pgqa-operator-group-1 pgqa-terminal-hash))

	   ;; In PG this is marked as right-associative, while documentation of
	   ;; Bison 2.7 declares it left-associative in examples. Perhaps the
	   ;; problem is that associativity is not applicable here at all - see
	   ;; chapter "5.3.3 Specifying precedence only" in the documentation of
	   ;; Bison 3.0.4.
	   '(nonassoc UMINUS)

	   ;; XXX PG core declares brackets as left-associative, but I have no
	   ;; idea in which situation the associativity is important.
	   '(nonassoc ?\[ ?\])
	   '(nonassoc ?\( ?\))

	   '(left ?.)
	   )
	  )

    ;; The rules are added to the beginning of the list, so high precedences
    ;; first.
    (setq rule-sublist-1
	  (pgqa-create-operator-rules
	   pgqa-operator-group-1 rule-sublist-1 pgqa-terminal-hash
	   'pgqa-create-binop-expr-rule))

    ;; Asterisk can also be used as wildcard in object names, so handle it
    ;; separate from the pgqa-operator-group-1 group. However the precedence
    ;; must match pgqa-operator-group-1.
    (push (pgqa-create-binop-expr-rule "*" ?* pgqa-precedence-times)
	  rule-sublist-1)

    ;; + and - can be used as unary operators, so they don't fit our concept of
    ;; groups. Create the rules separate.
    (push (pgqa-create-binop-expr-rule "+" ?+ pgqa-precedence-plus)
	  rule-sublist-1)
    (push (pgqa-create-binop-expr-rule "-" ?- pgqa-precedence-plus)
	  rule-sublist-1)

    (setq rule-sublist-1
	  (pgqa-create-operator-rules
	   ;; >, <, etc.
	   pgqa-operator-group-2 rule-sublist-1 pgqa-terminal-hash
	   'pgqa-create-binop-expr-rule))

    (setq rule-sublist-1
    	  (pgqa-create-operator-rules
	   ;; IS, ISNULL, NOTNULL
    	   pgqa-operator-group-3 rule-sublist-1 pgqa-terminal-hash
	   'pgqa-create-postfix-unop-expr-rule))

    (setq rule-sublist-1
    	  (pgqa-create-operator-rules
	   ;; NOT
    	   pgqa-operator-group-4 rule-sublist-1 pgqa-terminal-hash
	   'pgqa-create-prefix-unop-expr-rule))

    (setq rule-sublist-1
	  (pgqa-create-operator-rules
	   ;; AND
	   pgqa-operator-group-5 rule-sublist-1 pgqa-terminal-hash
	   'pgqa-create-binop-expr-rule))

    (setq rule-sublist-1
	  (pgqa-create-operator-rules
	   ;; OR
	   pgqa-operator-group-6 rule-sublist-1 pgqa-terminal-hash
	   'pgqa-create-binop-expr-rule))

    ;; TODO Create a group for these as well, and possibly replace
    ;; rule-sublist-1 and rule-sublist-2 with a single list. (The API was not
    ;; generic enough when this part was being implemented.)
    (push (pgqa-create-prefix-unop-expr-rule "+" ?+ pgqa-precedence-uminus
					     '[UMINUS])
	  rule-sublist-2)
    (push (pgqa-create-prefix-unop-expr-rule "-" ?- pgqa-precedence-uminus
					     '[UMINUS])
	  rule-sublist-2)

    (setq expr-rules

	  (seq-concatenate
	   'list

	   ;; Function expression.
	   '(
	     ;; It seems better to use sql-object and eliminate the
	     ;; inappropriate cases during analysis than to define another,
	     ;; very similar non-terminal.
	     ((sql-object ?( expr-list ?))
	      (make-instance 'pgqa-func-call
	     		     :name $1
	     		     :args $3
	     		     :region (pgqa-union-regions $region1 $1
	     						 $region4 $4))
	      )

	     ((sql-object ?( ?))
	      (make-instance 'pgqa-func-call
			     :name $1
			     :args nil
			     :region (pgqa-union-regions $region1 $1
							 $region3 $3))
	      )
	     )

	   ;; Single expression parenthesized or a row expression.
	   '(
	     ((?\( expr-list ?\))
	      (let ((l $2))
		(oset l region (pgqa-union-regions $region1 $1 $region3 $3))
		l)
	      )
	     )

	   rule-sublist-1

	   rule-sublist-2

	   '(
	     ((NUMBER)
	      (make-instance 'pgqa-number :value $1
			     :region (pgqa-get-nonterm-region $region1 $1))
	      )

	     ((STRING)
	      (make-instance 'pgqa-number :value $1
			     :region (pgqa-get-nonterm-region $region1 $1))
	      )

	     ((sql-object)
	      $1
	      )
	     )
	   ))

    (setq nonterm-expr (cons 'expr expr-rules))

    (setq grammar-list
	  (append
	   '(
	     ;; For terminals we've constructed terminals list which we'll
	     ;; eventually cons to the list beginning. The other elements are
	     ;; literals.
	     ;;
	     ;; Likewise, we'll cons separately constructed list
	     ;; nonterm-assoc that specifies associativity of non-terminal
	     ;; symbols.

	     ;; Non-terminals.
	     (input
	      ((query)
	       $1)

	      ((query ?\;)
	       (let ((q $1))
		 (oset q region (pgqa-union-regions nil q $region2 nil))
		 q)
	       )
	      )

	     (query
	      ((select-expr)
	       (make-instance 'pgqa-query :kind "SELECT"
			      ;; $1 should be instance of pgqa-expr, with
			      ;; comma operator as the single arg.
			      :target-expr (car (oref $1 args))
			      :region (pgqa-get-nonterm-region $region1 $1))
	       )

	      ((select-expr from-expr)
	       (make-instance 'pgqa-query :kind "SELECT"
			      :target-expr (car (oref $1 args))
			      :from-expr $2
			      :region (pgqa-union-regions nil $1 nil $2))
	       )

	      ((update-expr update-set-expr)
	       (make-instance 'pgqa-query :kind "UPDATE"
			      ;; $2 should be pgqa-expr, having the targetlist
			      ;; as the single element of args.
			      :target-expr (car (oref $2 args))
			      ;; Likewise, $1 wraps the target table.
			      :target-table (car (oref $1 args))
			      :region (pgqa-union-regions nil $1 nil $2))
	       )

	      ((update-expr update-set-expr where-expr)
	       (let ((from-expr
		      (make-instance 'pgqa-from-expr
				     :from-list nil
				     :qual (car (oref $3 args))
				     :region (pgqa-get-nonterm-region
					      nil $3))))
		 (make-instance 'pgqa-query :kind "UPDATE"
				:target-expr (car (oref $2 args))
				:target-table (car (oref $1 args))
				:from-expr from-expr
				:region (pgqa-union-regions nil $1 nil $3))
		 )
	       )

	      ((update-expr update-set-expr from-expr)
		 (make-instance 'pgqa-query :kind "UPDATE"
				:target-expr (car (oref $2 args))
				:target-table (car (oref $1 args))
				:from-expr $3
				:region (pgqa-union-regions nil $1 nil $3))
	       )
	      )

	     (select-expr
	      ((SELECT target-list)
	       (let* ((tl $2)
		      (args (oref tl :args))
		      (last (nth (1- (length args)) args)))
		 ;; Use pgqa-expr to transfer region info to the containing
		 ;; node.
		 (make-instance 'pgqa-expr
				:args (list tl) ;; `tl' is pgqa-operator
						;; instance (comma).
				:region (pgqa-union-regions
					 $region1 nil nil last)))
	       )
	      )

	     (update-expr
	      ;; Since the table can have alias, let's accept from-list-entry
	      ;; now and check for illegal kinds during analysis.
	      ((UPDATE from-list-entry)
	       ;; Use pgqa-expr to transfer region info to the containing
	       ;; node.
	       (make-instance 'pgqa-expr
			      :args (list $2)
			      :region (pgqa-union-regions
				       $region1 nil nil $2))
	       )
	      )

	     ;; TODO During analysis, set precedence of the top level "=" of
	     ;; each list entry low enough (pgqa-precedence-comma, renamed to
	     ;; something more generic, or introduce new special value,
	     ;; e.g. pgqa-precedence-assign) so that the right side is not
	     ;; parenthesized.
	     (update-set-expr
	      ((SET target-list)
	       ;; TODO A macro that creates the instance for update-set-expr,
	       ;; select-expr and returning-expr. Maybe for where-expr too.
	       (let* ((tl $2)
		      (args (oref tl :args))
		      (last (nth (1- (length args)) args)))
		 (make-instance 'pgqa-expr
				:args (list tl)
				:region (pgqa-union-regions
					 $region1 nil nil last)))
	       )
	      )

	     ;; Comma is treated like an operator with the lowest possible<
	     ;; precedence (so that it does not enforce unnecessary braces).
	     (target-list
	      ((target-entry)
	       (make-instance 'pgqa-operator
			      :op ","
			      :args (list $1)
			      :prec pgqa-precedence-comma
			      :region (pgqa-get-nonterm-region $region1 $1))
	       )

	      ((target-list ?, target-entry)
	       (let* ((tl $1)
		      (args (oref tl args))
		      (first (car args)))
		 ;; Append a single-element list. If we appended just the
		 ;; element, it'd result in a "dotted list" and such cannot be
		 ;; iterated easily.
		 (oset tl args (append args (list $3)))
		 ;; Propagate the region info of list elements to the FROM
		 ;; expression as whole.
		 (oset tl region (pgqa-union-regions nil first nil $3))
		 tl)
	       )
	      )

	     (target-entry
	      ((expr)
	       (make-instance 'pgqa-target-entry :expr $1
			      :region (pgqa-get-nonterm-region $region1 $1))
	       )

	      ((expr SYMBOL)
	       (make-instance 'pgqa-target-entry :expr $1 :alias $2
			      :region (pgqa-union-regions $region1 $1
							  $region2 $2))
	       )

	      ((expr AS SYMBOL)
	       (make-instance 'pgqa-target-entry :expr $1 :alias $3
			      :region (pgqa-union-regions $region1 $1
							  $region3 $3))
	       )
	      )

	     (from-expr
	      ((FROM from-list)
	       (let* ((l $2)
		      (last (nth (1- (length l)) l)))
		 (make-instance 'pgqa-from-expr :from-list l
				;; Propagate the region info of list elements
				;; to the FROM expression as whole.
				:region (pgqa-union-regions $region1 nil
							    nil last))))

	      ((FROM from-list where-expr)
	       (let ((qual (car (oref $3 args))))
		 (make-instance 'pgqa-from-expr :from-list $2 :qual qual
				:region (pgqa-union-regions
					 $region1 nil nil $3))
		 )
	       )
	      )

	     (where-expr
	      ((WHERE expr)
	       ;; Use pgqa-expr to transfer region info to the containing node.
	       (make-instance 'pgqa-expr :args (list $2)
			     :region (pgqa-union-regions
				      $region1 nil nil $2))))

	     (from-list
	      ((from-list-entry)
	       (list $1)
	       )

	      ((from-list ?, from-list-entry)
	       ;; See target-list for comment about appending single-item list.
	       (append $1 (list $3))
	       )
	      )

	     (join-op
	      ((JOIN)
	       ;; See the 'kind slot of pgqa-from-list-entry class.
	       nil
	       )

	      ((INNER JOIN)
	       nil
	       )

	      ((LEFT JOIN)
	       "left"
	       )

	      ((LEFT OUTER JOIN)
	       "left"
	       )

	      ((RIGHT JOIN)
	       "right"
	       )

	      ((RIGHT OUTER JOIN)
	       "right"
	       )

	      ((FULL JOIN)
	       "full"
	       )
	      )

	     (from-list-entry
	      ((from-list-entry join-op from-list-entry ON expr)
	       (make-instance 'pgqa-from-list-entry :args (list $1 $3)
			      :kind $2
			      :qual $5
			      :region (pgqa-union-regions $region1 $1
							  $region5 $5))
	       )

	      ((sql-object)
	       (make-instance 'pgqa-from-list-entry :args (list $1)
			      :region (pgqa-get-nonterm-region $region1 $1))
	       )

	      ((sql-object SYMBOL)
	       (make-instance 'pgqa-from-list-entry :args (list $1) :alias $2
			      :region (pgqa-union-regions $region1 $1
							  $region2 $2))
	       )

	      ((sql-object AS SYMBOL)
	       (make-instance 'pgqa-from-list-entry :args (list $1) :alias $3
			      :region (pgqa-union-regions $region1 $1
							  $region3 $3))
	       )

	      ;; Separate rules exist for a function in the FROM list. At
	      ;; least the alias (which can contain column list) makes it
	      ;; distinct from the function expression as defined in
	      ;; expr-rules. In fact, PG does require alias here, so the rules
	      ;; for function expressions would be useless.
	      ;;
	      ;; (Like with function expression, we need to check during
	      ;; analysis if the sql-object is acceptable, e.g. it's not a
	      ;; number or does not contain an asterisk.)
	      ((sql-object ?( expr-list ?) from-list-entry-alias)
	       (let* ((reg-fc (pgqa-union-regions $region1 $1 $region4 $4))
		      (fc (make-instance 'pgqa-func-call :name $1 :args $3
					 :region reg-fc))
		      (alias-expr $5)
		      ;; args slot of alias-expr contains a list whose only
		      ;; element is the alias symbol (string) - see
		      ;; from-list-entry-alias.
		      (alias (car (oref alias-expr args))))
		 (make-instance 'pgqa-from-list-entry :args (list fc)
				:alias alias
				:region (pgqa-union-regions nil fc nil
							    alias-expr)))
	       )

	      ((sql-object ?( ?) from-list-entry-alias)
	       (let* ((reg-fc (pgqa-union-regions $region1 $1 $region3 $3))
		      (fc (make-instance 'pgqa-func-call :name $1 :args nil
					  :region reg-fc))
		      (alias-expr $4)
		      (alias (car (oref alias-expr args))))
		 (make-instance 'pgqa-from-list-entry :args (list fc)
				:alias alias
				:region (pgqa-union-regions nil fc nil
							    alias-expr)))
	       )
	      )

	     ;; Alias of a function in the FROM list or that of a subquery.
	     (from-list-entry-alias
	      ((SYMBOL)
	       ;; Use generic expression, to transfer region info.
	       (make-instance 'pgqa-expr :args (list $1)
			      :region (pgqa-get-nonterm-region $region1 nil))
	       )

	      ((AS SYMBOL)
	       (make-instance 'pgqa-expr :args (list $2)
			      :region (pgqa-union-regions $region1 nil
							  $region2 nil))
	       )
	      )
	     )

	   '(
	     (expr-list
	      ((expr)
	       (make-instance 'pgqa-operator
			      :op ","
			      :args (list $1)
			      :prec pgqa-precedence-comma
			      :region (pgqa-get-nonterm-region $region1 $1))
	       )

	      ((expr-list ?, expr)
	       (let* ((orig $1)
		      (args (oref orig args))
		      (arg-first (car args)))
		 (oset $1 args (append args (list $3)))
		 (oset $1 region
		       (pgqa-union-regions $region1 $1 $region3 $3))
		 $1)
	       )
	      )
	     )

	   (list nonterm-expr)

	   '(
	     (sql-object
	      ((SYMBOL)
	       (make-instance 'pgqa-obj :args (list $1)
			      :region (pgqa-get-nonterm-region $region1 $1))
	       )

	      ((sql-object ?. SYMBOL)
	       (make-instance 'pgqa-obj
			      :args (append (oref $1 args) (list $3))
			      :region (pgqa-union-regions $region1 $1
							  $region3 $3))
	       )

	      ((?*)
	       (make-instance 'pgqa-obj :args (list $1)
			      :region (pgqa-get-nonterm-region $region1 $1))
	       )

	      ((sql-object ?. ?*)
	       (make-instance 'pgqa-obj :args (append (oref $1 args) (list $3))
			      :region (pgqa-union-regions $region1 $1
							  $region3 $3))
	       )
	      )

	     ;; (error
	     ;;  (progn "Error"))
	     )
	   ) ;; seq-concatenate
	  )

    (setq grammar-list
	  (cons nonterm-assoc grammar-list))

    ;; Now finish the grammar by adding the terminal symbols;
    (setq grammar-list (cons terminals grammar-list))

    (setq automaton (wisent-compile-grammar grammar-list))
    (setq pgqa-automaton automaton))
  )

;; This is the lexer function providing input for wisent parser.
(defun get-next-query-token ()
  (let ((tok)
	(kind)
	(pos)
	(value)
	(key)
	(result))
    (if (not (null query-tokens))
	(progn
	  (setq tok (pop query-tokens))
	  (setq kind (car tok))
	  (setq pos (cdr tok))
	  (setq start (car pos))
	  (setq end (cdr pos))
	  (setq value (buffer-substring-no-properties start end))
	  (setq result
		(list
		 (cond
		  ((and (eq kind 'symbol)
			(setq key (gethash (upcase value)
				       pgqa-keyword-hash nil))
			)
		   key)

		  ;; TODO Consider only assertion statement for the token
		  ;; kind, or removal of these conditions altogether.
		  ((and (or (eq kind 'punctuation) (eq kind 'symbol)
			    (eq kind 'open-paren) (eq kind 'close-paren))
			(setq key (gethash value pgqa-terminal-hash nil)))
		   key)

		  ((eq kind 'number)
		   'NUMBER)

		  ;; Generic symbol (table / column name, etc.)
		  ((eq kind 'symbol)
		   'SYMBOL)

		  ((and (eq kind 'string)
			(string= (substring value 0 1) "\""))
		   'SYMBOL)

		  ((eq kind 'string)
		   'STRING)

		  (t (nth 0 tok)))
		 value (vector start end))))
      (setq result (list wisent-eoi-term)))
    result))

;; Move point to the symbol that caused the error.
(defun pgqa-parse-message (msg &rest args)
  (let ((positions (nth 2 wisent-input)))
    (goto-char (elt positions 0))
    (setq pgqa-parse-error t)
    ;; Remove the (generated) operator symbols with the appropriate strings.
    (maphash
     (lambda (op sym)
       (if (symbolp sym)
	   (setq msg (replace-regexp-in-string
		      (symbol-name sym)
		      (format "'%s'" op) msg))))
     pgqa-terminal-hash)

    (user-error msg))
)

;; TODO Documentation string.
;;
;; TODO If pgqa-query-tree already exists, make sure its markers can be
;; garbage collected (even if the tree should be pushed to stack?).
;;
;; TODO Consider declaring and handling the parameters like fill-paragraph
;; does (especially with REGION).
(defun pgqa-parse ()
  "Parse the SQL query contained in the buffer and bind result to \
`pgqa-query-tree' variable. If the variable already contained another tree, \
it's replaced."
  (interactive)

  (setq pgqa-parse-error nil)

  (if (not (equal major-mode 'pgqa-mode))
      (user-error "Only contents of query buffer can be parsed."))
  (if (or (null pgqa-automaton) (not (null pgqa-parser-always-init)))
      (pgqa-init-parser))

  ;; TODO Check this needs to be repeated. Currently it seems related to
  ;; erase-buffer, which we call from pgqa-deparse. Preferrably it should only
  ;; be called from pgqa-init-parser.
  (semantic-lex-init)

  (let ((result)
	(start)
	(end))
    (if mark-active
	(progn
	  (setq start (region-beginning))
	  (setq end (region-end))
	  (deactivate-mark))
      (progn
	(setq start 0)
	(setq end (point-max))))

    (setq-local query-tokens (simple-lex start end (current-buffer))))

  (setq result
	(wisent-parse pgqa-automaton 'get-next-query-token
		      'pgqa-parse-message 'input))

  ;; Only update the existing tree if the parsing did complete.
  (if (null pgqa-parse-error)
      (progn
	(pgqa-set-markers result)
	(setq pgqa-query-tree result)
	))
  )

;; TODO Update markers during deparsing. (Should pgqa-set-markers take care?)
(defun pgqa-deparse (&optional indent)
  "Turn the tree stored in buffer-local variable `pgqa-query-tree' into text
and replace contents of the owning buffer with it.

The optional prefix argument INDENT tells how much should the query be
indented. If it's passed, then INDENT times `tab-width' spaces are inserted
in front of each line."
  (interactive "P")

  (if (not pgqa-query-tree)
      (user-error "No query has been parsed so far."))

  (if (null tab-width)
      (error "tab-width should not be nil"))

  (let* ((state)
	 (markers (oref pgqa-query-tree markers))
	 (start (elt markers 0))
	 (end (elt markers 1))
	 (init-col)
	 (init-str)
	 (leading-whitespace nil)
	 (indent-estimate 0))

    (save-excursion
      (goto-char start)
      (beginning-of-line)
      (setq init-col (- start (point)))
      (let ((line-start (point))
	    (query-start (+ (point) init-col)))

	(setq init-str (buffer-substring line-start query-start))
	(setq init-str-width (string-width init-str))

	(if (null
	     ;; Match means that there's at least non-whitespace character int
	     ;; init-str.
	     (string-match "\\S-+" init-str))
	    ;; The initial part of the line is only whitespace, so ignore
	    ;; it. (We could delete only terminating whitespace and decrement
	    ;; init-col accordingly, but it's not clear what user exactly
	    ;; expects in such case.)
	    (progn
	      ;; The query starts on the first position of the line or is
	      ;; preceded by whitespace.
	      (setq leading-whitespace t)

	      ;; Estimate the indentation while init-str-width still contains
	      ;; tab-width characters per \t.
	      (setq indent-estimate (/ init-str-width tab-width))
	      ;; If the estimate is less than half of tab-width below the next
	      ;; position, align it to that position.
	      (if (> (- init-str-width (* indent-estimate tab-width))
		     (/ tab-width 2))
		  (setq indent-estimate (1+ indent-estimate)))
	      )

	  ;; The first line contains non-whitespace characters, so we won't
	  ;; adjust init-col, but still need indent-estimate for the following
	  ;; rows. Unlike the whitespace case, do not try to match the
	  ;; indentation of the first row by adding extra \t - the first line
	  ;; probably shouldn't start at lower position than the next one(s).
	  (setq indent-estimate (/ init-str-width tab-width)))

	(if (and tab-width (> tab-width 1))
	    ;; init-str-width is the number of characters we need to delete,
	    ;; so count each \t exacly once.
	    (setq init-str-width
		  (- init-str-width (*
				     (how-many "\\\t" line-start
					       query-start)
				     (- tab-width 1))))
	  )
	)
      )

    ;; Move query start to the line start.
    (setq start (- start init-str-width))

    (if (null indent)
	(setq indent indent-estimate))

    (if leading-whitespace
	;; The leading whitespace will be removed from the first line. Only
	;; indent should be applied, no additional offset.
	(setq init-col 0)

      ;; The leading (non-whitespace) string will remain on the first line,
      ;; but make sure only init-col is applied to the first line (no
      ;; indentation).
      (if (and indent (> indent 0))
	    (setq init-col (- init-col (* indent tab-width)))))

    ;; indent shouldn't be nil for the next use.
    (unless indent
      (setq indent 0))

    (setq state (pgqa-init-deparse-state indent init-col))

    ;; The leading non-whitespace string replaces the indentation.
    (if (null leading-whitespace)
	(oset state result init-str))

    (atomic-change-group
      ;; The dump should also be in the atomic block, because of marker
      ;; changes.
      (pgqa-dump pgqa-query-tree state indent)

      (delete-region start end)

      (save-excursion
	(goto-char start)
	(insert (oref state result)))
      (pgqa-mode))
    )
  )

(provide 'pgqa-parser)
