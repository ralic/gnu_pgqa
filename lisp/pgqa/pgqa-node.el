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

(require 'eieio)

(defclass pgqa-node ()
  (
   (region
    :initarg :region
    :documentation "Start and end position of a nonterminal."
    )

   (markers
    :initarg :markers
    :documentation "Start and end position in the form of a marker."
    )
   )

  "Class representing a generic node of SQL query tree.")

(defclass pgqa-expr (pgqa-node)
  (
   (args :initarg :args)
   )
  "A node representing an operation on one or multiple arguments.")

;; Besides attaching the markers and overlays to nodes, add them to
;; pgqa-query-markers and pgqa-query-overlays lists, for easy cleanup.
(defun pgqa-setup-node-gui (node context)
  "Turn region(s) into a markers and add overlay(s) to the node."
  (let* ((reg-vec (oref node region))
	 (reg-start (elt reg-vec 0))
	 (reg-end (elt reg-vec 1))
	 (m-start (make-marker))
	 (m-end (make-marker))
	 (o))
    (set-marker m-start reg-start)
    (set-marker m-end reg-end)

    ;; The insertion types are such that the start and end markers always span
    ;; only the original region.
    (set-marker-insertion-type m-start t)
    (set-marker-insertion-type m-end nil)

    ;; Create an overlay and make it point at the node.
    (setq o (make-overlay m-start m-end))
    (overlay-put o 'node node)

    ;; Keep track of both markers and overlay.
    (push m-start pgqa-query-markers)
    (push m-end pgqa-query-markers)
    (push o pgqa-query-overlays)

    (oset node markers (vector m-start m-end)))
  )

;; For performance reasons (see the Overlays section of Elisp documentation)
;; we assign the face as text property, although cleanup would be simpler if
;; we assigned the face via overlay.
(defun pgqa-set-node-face (node context)
  (if (eq (eieio-object-class node) 'pgqa-operator)
      (let ((op-node (oref node op-node)))
	(if op-node
	    (let* ((m (oref op-node markers))
		   (m-start (elt m 0))
		   (m-end (elt m 1)))
	      (put-text-property m-start m-end
				 'font-lock-face 'pgqa-operator-face))
	  )
	)
    )
  )

;; Remove the face added previously by pgqa-set-node-face.
(defun pgqa-reset-node-face (node context)
  (if (eq (eieio-object-class node) 'pgqa-operator)
      (let ((op-node (oref node op-node)))
	(if op-node
	    (let* ((m (oref op-node markers))
		   (m-start (elt m 0))
		   (m-end (elt m 1)))
	      (remove-text-properties m-start m-end
				 '(font-lock-face nil)))
	  )
	)
    )
  )

;; `state' is an instance of `pgqa-deparse-state' class.
;;
;; `indent' determines indentation of the node, relative to (oref node
;; indent).
(defmethod pgqa-dump ((node pgqa-node) state indent)
  "Turn a node and its children into string."
  nil)

;; If buffer-pos is maintained, use it to adjust the start and end position of
;; the node.
(defun pgqa-dump-start (node state)
  (if (oref state buffer-pos)
      ;; Temporarily set the slot to plain number.
      (oset node region (oref state buffer-pos))))

(defun pgqa-dump-end (node state)
  (if (oref state buffer-pos)
      ;; Retrieve the start position stored by pgqa-dump-start and replace it
      ;; with 2-element vector.
      (let* ((start (oref node region))
	     (end (oref state buffer-pos))
	     (region (vector start end)))
	(oset node region region)))
  )

;; An utility to apply a function to all nodes of a tree.
;;
;; If the walker function changes the nodes, caller is responsible for having
;; taken a copy of the original node.
;;
;; Currently it seems more useful to process the sub-nodes before the actual
;; node.
(defmethod pgqa-node-walk ((node pgqa-node) walker context)
  "Run the walker function on sub-nodes and the node itself"

  ;; It seems safer to force each node to implement this function explicitly
  ;; than to process the node w/o sub-nodes here.
  (error (format "walker method not implemented for %s class"
		 (eieio-object-class-name node))))

(defun pgqa-node-walk-list (node-list walker context)
  "Run the node walker function on each item of a list."
  (dolist (node node-list)
    (pgqa-node-walk node walker context)))

;; Metadata to control deparsing of an SQL query and the contained
;; expressions.
;;
;; Note: the simplest way to control (not) breaking line in front of a
;; subquery is to create a separate instance of this class for the subquery.
;;
;; XXX If adding a new field, check if it's subject to backup / restore by
;; pgqa-dump method of pgqa-operator class. (Is this backup / restore worth
;; separate functions?)
(defclass pgqa-deparse-state ()
  (
   (indent
    :initarg :indent
    ;; The indentation passed to `pgqa-dump', `pgqa-deparse-string' and
    ;; subroutines is relative to this.
    :documentation "Indentation level of the top level query.")

   (indent-top-expr
    :initarg :indent-top-expr
    :documentation "Indentation, relative to `indent' above, of top level
expression, e.g. the text following top-level keyword. See
`pgqa-deparse-top-keyword' for details.")

   (next-column
    :initarg :next-column
    :documentation "Column at which the following node (or its leading space)
should start.")

   (next-space
    :initarg :next-space
    :documentation "The width of the next space to be printed out.")

   (line-empty
    :initarg :line-empty
    :documentation "Is the current line empty or contains only whitespace?")

   (buffer-pos
    :initarg :buffer-pos
    :documentation "Position in the output buffer at which the next string will end u."
    )

   (result
    :initarg :result
    :documentation "String to which each node appends its textual
representation.")
   )

  "State of the deparsing process."
  )

;; init-col-src is column (in addition to the indentation) at which the source
;; query starts.
(defun pgqa-init-deparse-state (indent init-col-src line-empty buffer-pos)
  "Initialize instance of `pgqa-deparse-state'."

  (let ((indent-width (* indent tab-width)))
    (make-instance 'pgqa-deparse-state
		   :indent indent
		   :indent-top-expr 0
		   :next-column (+ indent-width init-col-src)
		   :next-space 0
		   :line-empty t
		   :buffer-pos buffer-pos
		   :result (make-string indent-width 32))))

(defmethod pgqa-deparse-state-get-attrs ((state pgqa-deparse-state))
  "Return the slots of `pgqa-deparse-state' as an association list."
  (let ((result)
	(item))
    (dolist (key (object-slots state) result)
      (setq item (list key (slot-value state key)))
      (push item result))))

(defmethod pgqa-deparse-state-set-attrs ((state pgqa-deparse-state) slots)
  "Set slots of `pgqa-deparse-state' to values extracted by
`pgqa-deparse-state-get-attrs'."
  (dolist (slot slots)
    (set-slot-value state (car slot) (car (cdr slot)))))

(defmethod pgqa-deparse-newline ((state pgqa-deparse-state) indent)
  "Adjust deparse state so that deparsing continues at a new line, properly
indented."

  (let* ((indent-loc (+ indent (oref state indent)))
	 (indent-width (* indent-loc tab-width))
	 (result (oref state result)))
    (setq result (concat result "\n"))
    (setq result (concat result
			 (make-string indent-width 32)))
    (oset state result result)
    (oset state next-column indent-width)

    ;; buffer-pos might need to account for the strings added.
    (if (oref state buffer-pos)
	(oset state buffer-pos (+ (oref state buffer-pos) 1 indent-width)))

    (oset state line-empty t))
  )

(defmethod pgqa-deparse-space ((state pgqa-deparse-state))
  "Write space to deparsing output."
  (let ((space (oref state next-space)))
    (oset state result
	  (concat (oref state result)
		  (make-string space 32)))
    (oset state next-column (+ (oref state next-column) space))

    ;; buffer-pos might need to account for the strings added.
    (if (oref state buffer-pos)
	(oset state buffer-pos (+ (oref state buffer-pos) space))))

  ;; Restore the default value of next-space.
  (oset state next-space 1))

;; Prepare for insertion of `str', i.e. add line break or space, as
;; needed.
(defmethod pgqa-deparse-string-prepare ((state pgqa-deparse-state) str indent)
  (let ((col-incr 0)
	(space (oref state next-space)))
    (if (> space 0)
	(setq col-incr (1+ col-incr)))
    (setq col-incr (+ col-incr (string-width str)))

    ;; Zero space currently can't be broken.
    ;;
    ;; TODO Consider if there are special cases not to subject to this
    ;; restriction, and maybe introduce custom variable that allows breaking
    ;; even the zero space.
    (if (and fill-column (> space 0)
	     (> (+ (oref state next-column) col-incr) fill-column))
	(progn
	  (pgqa-deparse-newline state indent)
	  ;; No space (in addition to indentation) after newline.
	  (oset state next-space 0)))

    (pgqa-deparse-space state))
  )

(defmethod pgqa-deparse-string ((state pgqa-deparse-state) str indent)
  "Write arbitrary string to deparsing output."

  (pgqa-deparse-string-prepare state str indent)

  ;; In some cases we stick the next string to the current one w/o space
  ;; (which currently makes newline impossible - see
  ;; pgqa-deparse-string-prepare).
  (if (or
       (string= str "(") (string= str "["))
      (oset state next-space 0))

  (oset state result (concat (oref state result) str))

  (let ((str-width (string-width str)))
    (oset state next-column (+ (oref state next-column) str-width))

    ;; buffer-pos might need to account for the strings added.
    (if (oref state buffer-pos)
	(oset state buffer-pos (+ (oref state buffer-pos) str-width))))

  ;; clear line-empty if there string contains non-whitespace character.
  (if (string-match "\\S-" str)
      (oset state line-empty nil)))

;; Top-level keyword might deserve special attention, e.g. adding tabs between
;; itself and the following expression.
;;
;; `first' indicates that this is the first top-level keyword of the whole
;; query.
(defmethod pgqa-deparse-top-keyword ((state pgqa-deparse-state) keyword first)
  "Dump top-level keyword (SELECT, INSERT, FROM, WHERE, etc.)"

  (let ((first-offset 0))
    ;; For the structured output, all top-level keywords except for the first
    ;; one need line break.
    (if (and pgqa-multiline-query (null first))
	(progn
	  (pgqa-deparse-newline state 0)
	  ;; No space in front of the keyword, even if the keyword does not
	  ;; cause line break itself.
	  (oset state next-space 0))
      )

    ;; The first line of the deparsed query may be indented more than the rest
    ;; (see indent-estimate in pgqa-deparse).
    (if (and pgqa-multiline-query first)
	(setq first-offset
	      (- (oref state next-column)
		 (* (oref state indent) tab-width))))

    (pgqa-deparse-string state keyword
			 (if pgqa-multiline-query 1 0))

    (if (and pgqa-multiline-query (null pgqa-clause-newline))
	;; Ensure the appropriate space in front of the following expression.
	(let* ((indent-top-expr (oref state indent-top-expr))
	       (nspaces (- (* indent-top-expr tab-width) (string-width keyword))))

	  ;; Anything wrong about computation of indent-top-expr?
	  (if (< nspaces 1)
	      (error "indent-top-expr is too low"))

	  ;; No extra space if the next text would exceed fill-column.
	  (if (and
	       fill-column
	       (>= (+ (oref state next-column) nspaces) fill-column))
	      (setq nspaces 1))

	  ;; Shorten the space so that the expression (most likely column
	  ;; list) starts at the same position as the other expressions
	  ;; (e.g. table list).
	  (if (> first-offset 0)
	      (progn
		(setq nspaces (- nspaces first-offset))
		;; Make sure at least one space is left.
		(if (< nspaces 1)
		    (setq nspaces 1))))

	  (oset state next-space nspaces))
      )
    )

  (if pgqa-clause-newline
      ;; Avoid the single space that pgqa-dump of pgqa-operator class puts in
      ;; front of operators.
      (oset state next-space 0))
  )

(defclass pgqa-query (pgqa-node)
  (
   (kind :initarg :kind)
   (target-expr :initarg :target-expr)
   (from-expr :initarg :from-expr)
   (group-expr :initarg :group-expr)
   (order-expr :initarg :order-expr)
   ;; Table subject to INSERT / UPDATE / DELETE.
   (target-table :initarg :target-table)
   )
  "A generic SQL query (or subquery).")

;; In this subclass the function does not need the `indent' argument - the
;; base indentation is controlled by (oref state indent). (EIEIO does not
;; allow omitting the argument altogether.)
(defmethod pgqa-dump ((node pgqa-query) state &optional indent)
  "Turn query into a string."

  (pgqa-dump-start node state)
  ;; For mutiline output, compute the first column for expressions.
  ;;
  ;; TODO Adjust when adding the missing keywords.
  (if pgqa-multiline-query
      (let ((top-clauses)
	    (max-width 0)
	    (indent-expr))
	(if (slot-boundp node 'target-expr)
	    (push "SELECT" top-clauses))

	(if (slot-boundp node 'target-table)
	    (push "UPDATE" top-clauses))

	(if (slot-boundp node 'from-expr)
	    (let ((fe (oref node from-expr)))
	      (if (> (length (oref fe from-list)) 0)
		  (push "FROM" top-clauses))
	      (if (slot-boundp fe 'qual)
		  (push "WHERE" top-clauses))
	      ))

	(if (slot-boundp node 'group-expr)
	    (push "GROUP BY" top-clauses))

	(if (slot-boundp node 'order-expr)
	    (push "ORDER BY" top-clauses))

	;; Find out the maximum length.
	(dolist (i top-clauses)
	  (let ((width (string-width i)))
	    (if (> width max-width)
		(setq max-width width))))

	;; At least one space must follow.
	(setq max-width (1+ max-width))

	;; Round up to the nearest multiple of tab-width.
	(setq max-width
	      (+ max-width
		 (- tab-width (% max-width tab-width))))

	(oset state indent-top-expr (/ max-width tab-width)))
    )

  (let ((indent-clause))
    (if pgqa-clause-newline
	(setq indent-clause 1)
      ;; Extra tab might have been added in front of the clause (to ensure
      ;; that all clauses of the query start at the same position), so all
      ;; lines of the clause must start at that position.
      (setq indent-clause (oref state indent-top-expr)))

    (if (string= (oref node kind) "SELECT")
	(let ((te (oref node target-expr)))
	  (pgqa-deparse-top-keyword state "SELECT" t)

	  ;; Enforce line break if necessary.
	  ;;
	  ;; TODO The same for ORDER BY, WINDOW, LIMIT, etc.
	  (if pgqa-clause-newline
	      (pgqa-deparse-newline state indent-clause))

	  (pgqa-dump te state indent-clause)))

    (if (string= (oref node kind) "UPDATE")
	(let ((tt (oref node target-table))
	      (te (oref node target-expr)))
	  (pgqa-deparse-top-keyword state "UPDATE" t)
	  (pgqa-dump tt state indent-clause)
	  (pgqa-deparse-top-keyword state "SET" nil)
	  (pgqa-dump te state indent-clause)))

    (if (slot-boundp node 'from-expr)
	(let ((from-expr (oref node from-expr)))
	  ;; Update may or may not have FROM clause.
	  (pgqa-dump from-expr state 0)))

    (if (slot-boundp node 'group-expr)
	(pgqa-dump (oref node group-expr) state 0))

    (if (slot-boundp node 'order-expr)
	(pgqa-dump (oref node order-expr) state 0))
    )
  (pgqa-dump-end node state))

(defmethod pgqa-node-walk ((node pgqa-query) walker context)
  (if (slot-boundp node 'target-expr)
      (pgqa-node-walk (oref node target-expr) walker context))

  (if (slot-boundp node 'target-table)
      (pgqa-node-walk (oref node target-table) walker context))

  (if (slot-boundp node 'from-expr)
      (let ((fe (oref node from-expr)))
	(if (oref fe from-list)
	    (pgqa-node-walk-list (oref fe from-list) walker context))
	(if (slot-boundp fe 'qual)
	    (pgqa-node-walk (oref fe qual) walker context))))

  (if (slot-boundp node 'group-expr)
      (pgqa-node-walk (oref node group-expr) walker context))

  (if (slot-boundp node 'order-expr)
      (pgqa-node-walk (oref node order-expr) walker context))

  (funcall walker node context))

(defclass pgqa-from-expr (pgqa-node)
  (
   (from-list :initarg :from-list)
   (qual :initarg :qual)
   )
  "FROM expression of an SQL query."
)

(defmethod pgqa-dump ((node pgqa-from-expr) state indent)
  (pgqa-dump-start node state)

  (let ((from-list (oref node from-list))
	(indent-clause))

    ;; See the related comment in pgqa-dump method of pgqa-query class.
    (if pgqa-clause-newline
	(setq indent-clause (1+ indent))
      (setq indent-clause (oref state indent-top-expr)))

    ;; INSERT, UPDATE or DELETE statement can have the list empty.
    (if (> (length from-list) 0)
	(progn
	  (pgqa-deparse-top-keyword state "FROM" nil)

	  (if pgqa-clause-newline
	      (pgqa-deparse-newline state indent-clause))

	  (if (= (length from-list) 1)
	      (pgqa-dump (car from-list) state indent-clause)
	    ;; Line breaks and indentation are best handled if we turn the list
	    ;; into a comma operator.
	    ;;
	    ;; XXX Shouldn't this be done by parser?
	    (let (
		  (l (make-instance 'pgqa-operator :op ","
				    :args from-list
				    :prec pgqa-precedence-comma))
		  )
	      (pgqa-dump l state indent-clause)
	      )
	    )
	  )
      )
    )

  (if (slot-boundp node 'qual)
      (let ((indent-clause))
	;; Like above. XXX Should the whole body of the function be wrapped in
	;; an extra "let" construct, which initializes the variable only
	;; once?)
	(if pgqa-clause-newline
	    (setq indent-clause (1+ indent))
	  (setq indent-clause (oref state indent-top-expr)))

	;; `space' should be up-to-date as the FROM clause is mandatory.
	(pgqa-deparse-top-keyword state "WHERE" nil)
	(if pgqa-clause-newline
	    (pgqa-deparse-newline state indent-clause))
	(pgqa-dump (oref node qual) state indent-clause)))
  (pgqa-dump-end node state))

;; A single argument represents table, function, subquery or VALUES clause. If
;; the 'args slot has elements, the FROM list entry is a join.
(defclass pgqa-from-list-entry (pgqa-expr)
  (
   ;; Instance of pgqa-from-list-entry-alias.
   (alias :initarg :alias)
   ;; For a simple entry, the value is one of "table", "function", "query",
   ;; "values". For join it's "left", "rignt", "full" (nil implies inner join
   ;; as long as 'args has 2 elements).
   (kind :initarg :kind)

   ;; Join expression if the entry is a join.
   (qual :initarg :qual)
   )
  "From list entry (table, join, subquery, ...)"
)

(defmethod pgqa-dump ((node pgqa-from-list-entry) state indent)
  "Print out FROM list entry (table, join, subquery, etc.)."

  (pgqa-dump-start node state)
  (let* ((args (oref node args))
	 (nargs (length args))
	 (is-join (= nargs 2))
	 (arg (car args))
	 (arg-is-query (eq (eieio-object-class arg) 'pgqa-query)))
    (cl-assert (or (= nargs 1) (= nargs 2)))

    (if (and is-join pgqa-join-newline
	     ;; Only break the line if it hasn't just happened for any reason.
	     (null (oref state line-empty)))
	(progn
	  (oset state next-space 0)
	  (pgqa-deparse-newline state indent)))

    (if (null arg-is-query)
	(pgqa-dump arg state indent)
      (pgqa-dump-from-list-query arg state indent))

    (if is-join
	(progn
	  (if pgqa-multiline-join
	      (progn
		(oset state next-space 0)
		(pgqa-deparse-newline state indent)))

	  (let ((kind (oref node kind)))
	    (if kind
	      (pgqa-deparse-string state (upcase kind) indent)))
	  (pgqa-deparse-string state "JOIN" indent)

	  (setq arg (nth 1 args))
	  (pgqa-dump arg state indent)

	  (pgqa-deparse-string state "ON" indent)

	  (pgqa-dump (oref node qual) state
		     (if pgqa-multiline-query (1+ indent) indent))))

    (if (slot-boundp node 'alias)
	(pgqa-dump (oref node alias) state indent))
    )
  (pgqa-dump-end node state))

(defmethod pgqa-node-walk ((node pgqa-from-list-entry) walker context)
  (if (slot-boundp node 'alias)
      (funcall walker (oref node alias) context))
  (if (slot-boundp node 'qual)
      (funcall walker (oref node qual) context))
  (funcall walker node context))

;; Query in the FROM list is not a typical from-list-entry.
;;
;; TODO Consider custom variable that controls whether parentheses are on the
;; same lines the query starts and ends respectively.
(defun pgqa-dump-from-list-query (query state indent)
  ;; XXX Can we do anything batter than breaking the line if either or
  ;; pgqa-join-newline or pgqa-multiline-join (or both) are nil?
  (if (and (null (oref state line-empty)) pgqa-multiline-query)
      (progn
	(oset state next-space 0)
	(pgqa-deparse-newline state indent)))

  (pgqa-deparse-string state "(" indent)

  (let ((state-loc state))
    (if pgqa-multiline-query
	;; Use a separate state to print out query.
	;;
	;; init-col-src of 1 stands for the opening parenthesis.
	(progn
	  (setq state-loc (pgqa-init-deparse-state
			   (+ (oref state indent) indent) 1 t
			   (oref state buffer-pos)))
	  (oset state-loc next-column (oref state next-column))
	  (oset state-loc result (oref state result))))

    (pgqa-dump query state-loc 0)
    (oset state result (oref state-loc result)))

  (oset state next-space 0)
  (pgqa-deparse-string state ")" indent)
)

;; TODO Store argument list to :args if the alias has some.
(defclass pgqa-from-list-entry-alias (pgqa-expr)
  (
   (name :initarg :name)
   )
  "From list entry alias."
)

(defmethod pgqa-dump ((node pgqa-from-list-entry-alias) state indent)
  "Turn alias into a string."
  (pgqa-deparse-string state "AS" indent)
  (pgqa-deparse-string state (oref node name) indent))

(defclass pgqa-sortgroup-expr (pgqa-expr)
  (
   ;; t and nil mean GROUP BY and ORDER BY respectively.
   (is-group :initarg :is-group)
   )
  "GROUP BY or ORDER BY expression."
)

(defmethod pgqa-dump ((node pgqa-sortgroup-expr) state indent)
  (pgqa-dump-start node state)

  (let* ((indent-clause)
	 (expr-tmp)
	 (kwd)
	 (args (oref node args))
	 ;; See group-expr rule in pgqa-parser.el.
	 (comma (car args)))

    (setq kwd
	  (if (oref node is-group)
	      "GROUP BY"
	    "ORDER BY"))

    (pgqa-deparse-top-keyword state kwd nil)

    ;; See the related comment in pgqa-dump method of pgqa-query class.
    (if pgqa-clause-newline
	(setq indent-clause (1+ indent))
      (setq indent-clause (oref state indent-top-expr)))

    (if pgqa-clause-newline
	(pgqa-deparse-newline state indent-clause))

    (pgqa-dump comma state indent-clause))
  (pgqa-dump-end node state))

(defclass pgqa-func-call (pgqa-node)
  (
   (name :initarg :name)
   ;; arguments are stored as a single pgqa-operator having :op=",".
   (args :initarg :args)
   )
  "Function call"
)

(defmethod pgqa-node-walk ((node pgqa-func-call) walker context)
  (funcall walker (oref node name) context)
  (if (oref node args)
      (pgqa-node-walk walker (oref node args) context))
  (funcall walker node context))

(defmethod pgqa-dump ((node pgqa-func-call) state indent)
  "Print out function call"

  (pgqa-dump (oref node name) state indent)

  ;; No space between function name and the parenthesis.
  (oset state next-space 0)
  (pgqa-deparse-string state "(" indent)
  (let ((args (oref node args)))
    (if (> (length args) 0)
	(pgqa-dump args state indent)))
  ;; Likewise, no space after.
  (oset state next-space 0)
  (pgqa-deparse-string state ")" indent)
)

;; Number is currently stored as a string - should this be changed?
(defclass pgqa-number (pgqa-node)
  (
   (value :initarg :value)
   )
  "A number.")

(defmethod pgqa-dump ((node pgqa-number) state indent)
  "Turn number into a string."

  (pgqa-dump-start node state)

  (let ((str (oref node value)))
    (pgqa-deparse-string state str indent))

  (pgqa-dump-end node state))

(defmethod pgqa-node-walk ((node pgqa-number) walker context)
  (funcall walker node context))

(defclass pgqa-obj (pgqa-expr)
  (
   ;; The :args slot (inherited from pgqa-expr) contains the dot-separated
   ;; components of table / column reference.
   ;;
   ;; XXX Can't we simply use pgqa-expr class here?
   ;;
   ;; x.y expression can represent either column "y" of table "x" or table "y"
   ;; of schema "x". Instead of teaching parser to recognize the context (is
   ;; it possible?) let's postpone resolution till analysis phase.
   ;;
   ;; Note that the number of arguments is not checked during "raw parsing",
   ;; and that asterisk can be at any position, not only the last one.
   )
  "Table or column reference.")

(defmethod pgqa-dump ((node pgqa-obj) state indent)
  "Turn an SQL object into a string."

  (pgqa-dump-start node state)
  (let ((str (mapconcat 'format (oref node args) ".")))
    (pgqa-deparse-string state str indent))
  (pgqa-dump-end node state))

(defmethod pgqa-node-walk ((node pgqa-obj) walker context)
  ;; The individual args are strings, so only process the alias.
  (funcall walker node context))

(defclass pgqa-operator (pgqa-expr)
  (
   (op :initarg :op)

   ;; Region info and marker of the operator string is stored separate so that
   ;; access to the string remains straightforward.
   (op-node :initarg :op-node
	    :initform nil)

   (prec :initarg :prec
	 :documentation "Operator precedence, for the sake of printing.")
   (postfix :initarg :postfix
	    :initform nil
	    :documentation "If the expression has only one argument, it's
considered to be an unary operator. This slot tells whether it's a postfix
operator. nil indicates it's a prefix operator.")
   )
  "Generic operator.")

;; TODO Some other constructs need parentheses, e.g. query in a
;; sublink. Should they be given certain precedence just because of this?
(defun pgqa-child-needs-parens (node arg)
  "Find out if argument of an operator node should be parenthesized."
  (if (eq (eieio-object-class node) 'pgqa-query)
      ;; Query as an argument should always be parenthesized.
      t
    (let ((prec (oref node prec))
	  (prec-child
	   (if (object-of-class-p arg pgqa-operator)
	       (oref arg prec))))
      (and prec prec-child (> prec prec-child))))
  )

(defun pgqa-is-multiline-operator (node)
  "Should the argument be printed in structured way?"

  (if (and pgqa-multiline-operator
	   (eq (eieio-object-class node) 'pgqa-operator))
      (let ((op (oref node op)))

	;; Comma is not a multi-line operator as such, only its arguments
	;; are.
	(null (string= op ",")))
    )
  )

;; indent relates to the operator, not argument.
(defun pgqa-indent-operator-first-argument (state indent arg-idx)
  "Prepare position for the first argument of a multiline operator."

  (let* ((s (oref state result))
	 (i (1- (length s))))
    (if
	;; No duplicate newline if we already have one.
	(and pgqa-clause-newline (= arg-idx 0) (oref state line-empty))
	(let ((indent-extra
	       (-
		;; indent argument of the function is relative to (oref state
		;; indent), so compute "absolute value".
		(+ (oref state indent) indent)
		(/ (oref state next-column) tab-width))))
	  ;; indent is for the operator, so add 1 more level for the argument.
	  (setq indent-extra (1+ indent-extra))
	  (oset state result
		(concat (oref state result)
			(make-string (* indent-extra tab-width) 32))))
      (progn
	(pgqa-deparse-newline state (1+ indent))
	(oset state next-space 0))))
  )

(defmethod pgqa-dump ((node pgqa-operator) state indent)
  "Turn operator expression into a string."

  (pgqa-dump-start node state)
  (let* ((args (oref node args))
	 (nargs (length args))
	 (op (oref node op))
	 (is-unary
	  (null
	   (or (cdr args)
	       ;; comma operator can have a single arg, so test explicitly.
	       (string= op ","))))
	 (is-comma (string= op ","))
	 (i 0)
	 (multiline
	  (and
	   pgqa-multiline-operator
	   (pgqa-is-multiline-operator node)))
	 (arg-multiline-prev))

    (dolist (arg args)
      (let* ((parens (pgqa-child-needs-parens node arg))
	     (state-backup)
	     (arg-is-operator (eq (eieio-object-class arg) 'pgqa-operator))
	     (arg-is-comma (and arg-is-operator (string= (oref arg op) ",")))
	     (arg-is-te (eq (eieio-object-class arg) 'pgqa-target-entry))
	     ;; FROM list entry?
	     (arg-is-fe (eq (eieio-object-class arg) 'pgqa-from-list-entry))
	     (arg-multiline)
	     (indent-arg indent))

	(if arg-is-te
	    (setq arg-multiline (pgqa-is-multiline-operator (oref arg expr)))
	  (setq arg-multiline (pgqa-is-multiline-operator arg)))

	(if (or (and is-unary (null (oref node postfix))) (> i 0))
	    (let ((omit-space))

	      ;; Never put space in front of comma.
	      (setq omit-space is-comma)

	      ;; Should each arg start at a new line?
	      (if multiline
		  (progn
		    (pgqa-deparse-newline state indent)
		    (setq omit-space t)))

	      (if omit-space
	      	  (oset state next-space 0))

	      ;; Use pgqa-dump-start / pgqa-dump-end to mark set the region of
	      ;; the operator string. This is needed so we can eventually
	      ;; assign face to the string.
	      (if (oref node op-node)
		  (pgqa-dump-start (oref node op-node) state))

	      (pgqa-deparse-string state op indent)

	      (if (oref node op-node)
		  (pgqa-dump-end (oref node op-node) state)))

	  )

	;; Ensure correct initial position for the argument output in case the
	;; operator spans multiple lines.
	(if multiline
	    ;; If the arg is also an operator, it'll take care of the newline
	    ;; (and correct indentation) itself. Otherwise we need to break
	    ;; the line and indent explicitly.
	    ;;
	    ;; An exception is if the current operator (i.e. not the argument)
	    ;; is unary prefix - it looks better if both operator and argument
	    ;; end up on the same line. Again, if the argument of the unary
	    ;; operator is operator itself (which includes parentheses), it'll
	    ;; take care of the line breaks automatically.
	    (if (and
		 (null arg-is-operator)
		 (or (> (length args) 1) (oref node postfix)))
		(pgqa-indent-operator-first-argument state indent i)
	      )

	  (if (and is-comma (null arg-multiline))
	      (if (or
		   ;; If an "ordinary" expression follows a multi-line
		   ;; operator within comma operator (e.g. SELECT list), break
		   ;; the line so that the multi-line operator does not share
		   ;; even a single line with the current argument.
		   ;;
		   ;; TODO Consider a custom variable to switch this behavior
		   ;; on / off.
		   arg-multiline-prev

		   ;; Definitely break the line if user requires each target
		   ;; list / from list entry to begin on a new line.
		   ;;
		   ;; Do nothing for i = 0 because pgqa-clause-item-newline
		   ;; requires pgqa-clause-newline to be set, which takes care
		   ;; of the first entry. Only take action if the comma is a
		   ;; target list of FROM list (i.e. do not affect things like
		   ;; function argument list).
		   (and pgqa-clause-item-newline (> i 0)
			(or arg-is-te arg-is-fe)))
		(progn
		  (pgqa-deparse-newline state indent)
		  (oset state next-space 0))))
	  )

	(if parens
	    (progn
	      (if multiline
		  ;; "(" should appear on a new line, indented as the argument
		  ;; would be if there were no parentheses. (The argument
		  ;; itself will eventually be given extra indentation.)
		  (pgqa-indent-operator-first-argument state indent i))

	      (pgqa-deparse-string state "(" indent)
	      ;; No space, whatever follows "(".
	      (oset state next-space 0)))

	;; Comma needs special treatment because it doesn't look nice if it's
	;; the first character on a line.
	;;
	;; Backup the slots but keep the instance so that callers still see
	;; our changes.
	(setq state-backup (pgqa-deparse-state-get-attrs state))

	;; Serialize the argument now, giving it additional indentation if
	;; user wants the output structured.
	(let ((indent-extra 0))
	  (if multiline
	      (progn
		(setq indent-extra (1+ indent-extra))
		;; The extra indentation due to parentheses, mentioned above.
		(if parens
		    (setq indent-extra (1+ indent-extra)))))
	  (setq indent-arg (+ indent indent-extra))
	  (pgqa-dump arg state indent-arg))

	(if
	    ;; If the argument has reached fill-column, line should have
	    ;; broken in front of the argument. So restore the previous state
	    ;; and dump the argument again, with fill-column temporarily
	    ;; decreased by one. That should make the argument appear on the
	    ;; new line too.
	    (and
	     (>= (oref state next-column) fill-column)
	     (< i (1- nargs)))
	    (progn
	      (pgqa-deparse-state-set-attrs state state-backup)

	      ;; TODO Loop until the line is broken correctly, but don't let
	      ;; fill-column reach value that lets little or no space on the
	      ;; line. But only try once if the related custom variable(s)
	      ;; allow for line break between opening paren and the following
	      ;; character or closing paren and the preceding character.
	      (let ((fill-column (1- fill-column)))
		(pgqa-dump arg state indent-arg))
	      )
	  )

	(if parens
	    (progn
	      ;; The closing parenthesis should be on a separate line, like
	      ;; the opening one.
	      (if (and multiline
		       ;; Row expression is not considered a multi-line
		       ;; operator, so it looks better if the ")" is stuck to
		       ;; it.
		       ;;
		       ;; TODO Verify the behavior when the last expression of
		       ;; the row is a multi-line operator.
		       (or (null arg-is-comma) (= (length (oref arg args)) 1)))
		  (pgqa-deparse-newline state (1+ indent)))
	      ;; Never space in front of ")".
	      (oset state next-space 0)
	      (pgqa-deparse-string state ")" indent)))

	(if (and is-unary (oref node postfix))
	    (progn
	      ;; TODO This part appears above for binary and unary prefix
	      ;; operators. Move it into a new function
	      ;; (pgqa-deparse-op-string?)
	      (if (oref node op-node)
		  (pgqa-dump-start (oref node op-node) state))

	      (pgqa-deparse-string state op indent)

	      (if (oref node op-node)
		  (pgqa-dump-end (oref node op-node) state))))

	(setq i (1+ i))

	(setq arg-multiline-prev arg-multiline))
      )
    )
  (pgqa-dump-end node state))

(defmethod pgqa-node-walk ((node pgqa-operator) walker context)
  (pgqa-node-walk-list (oref node args) walker context)
  (if (oref node op-node)
      (funcall walker (oref node op-node) context))
  (funcall walker node context))

(defclass pgqa-target-entry (pgqa-node)
  (
   (expr :initarg :expr)
   (alias :initarg :alias)
   )
  "Target list entry")

(defmethod pgqa-dump ((node pgqa-target-entry) state indent)
  "Turn target list entry into a string."

  (pgqa-dump-start node state)
  (pgqa-dump (oref node expr) state indent)

  (if (slot-boundp node 'alias)
      (progn
	(pgqa-deparse-string state "AS" indent)
	(pgqa-deparse-string state (oref node alias) indent))
    )
  (pgqa-dump-end node state))

(defmethod pgqa-node-walk ((node pgqa-target-entry) walker context)
  (pgqa-node-walk (oref node expr) walker context)
  (funcall walker node context))

(provide 'pgqa-node)
