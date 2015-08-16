;;;; Copyright (c) 2011-2015 Henry Harrington <henry.harrington@gmail.com>
;;;; This code is licensed under the MIT license.

;;;; Lower anything that modifies the special stack to explicit compiler builtins.

(in-package :sys.c)

(defvar *special-bindings*)
(defvar *verify-special-stack* nil)

(defun lsb-lambda (lambda)
  (let ((*current-lambda* lambda)
        (*special-bindings* '()))
    ;; Check some assertions.
    ;; No keyword arguments, no special arguments, no non-constant
    ;; &optional init-forms and no non-local arguments.
    (assert (not (lambda-information-enable-keys lambda)) (lambda)
            "&KEY arguments did not get lowered!")
    (assert (every (lambda (arg)
                     (lexical-variable-p arg))
                   (lambda-information-required-args lambda))
            (lambda) "Special required arguments did not get lowered!")
    (assert (every (lambda (arg)
                     (and (lexical-variable-p (first arg))
                          (quoted-form-p (second arg))
                          (or (null (third arg))
                              (lexical-variable-p (first arg)))))
                   (lambda-information-optional-args lambda))
            (lambda) "Special or complex optional arguments did not get lowered!")
    (assert (or (null (lambda-information-rest-arg lambda))
                (lexical-variable-p (lambda-information-rest-arg lambda)))
            (lambda) "Special rest argument did not get lowered!")
    (setf (lambda-information-body lambda)
          (lsb-form (lambda-information-body lambda)))
    (when (and *verify-special-stack*
               (not (find 'sys.int::suppress-ssp-checking
                          (getf (lambda-information-plist lambda) :declares)
                          :key #'first)))
      (let ((ssp (make-instance 'lexical-variable
                                :name (gensym "ssp")
                                :definition-point lambda)))
        (setf (lambda-information-body lambda)
              (make-instance 'ast-let
                             :bindings (list (list ssp (make-instance 'ast-call
                                                                      :name 'sys.int::%%special-stack-pointer
                                                                      :arguments '())))
                             :body (make-instance 'ast-multiple-value-prog1
                                                  :value-form (lambda-information-body lambda)
                                                  :body (make-instance 'ast-if
                                                                       :test (make-instance 'ast-call
                                                                                            :name 'eq
                                                                                            :arguments (list ssp
                                                                                                             (make-instance 'ast-call
                                                                                                                            :name 'sys.int::%%special-stack-pointer
                                                                                                                            :arguments '())))
                                                                       :then (make-instance 'ast-quote :value 'nil)
                                                                       :else (make-instance 'ast-call
                                                                                            :name 'error
                                                                                            :arguments (list (make-instance 'ast-quote :value "SSP mismatch")))))))))
    lambda))

(defun lsb-form (form)
  (etypecase form
    (ast-block
     (lsb-block form))
    (ast-function form)
    (ast-go
     (lsb-go form))
    (ast-if
     (make-instance 'ast-if
                    :test (lsb-form (test form))
                    :then (lsb-form (if-then form))
                    :else (lsb-form (if-else form))))
    (ast-let
     (lsb-let form))
    (ast-multiple-value-bind
     (make-instance 'ast-multiple-value-bind
                    :bindings (bindings form)
                    :value-form (lsb-form (value-form form))
                    :body (lsb-form (body form))))
    (ast-multiple-value-call
     (make-instance 'ast-multiple-value-call
                    :function-form (lsb-form (function-form form))
                    :value-form (lsb-form (value-form form))))
    (ast-multiple-value-prog1
     (make-instance 'ast-multiple-value-prog1
                    :value-form (lsb-form (value-form form))
                    :body (lsb-form (body form))))
    (ast-progn
     (make-instance 'ast-progn
                    :forms (mapcar #'lsb-form (forms form))))
    (ast-quote form)
    (ast-return-from
     (lsb-return-from form))
    (ast-setq
     (make-instance 'ast-setq
                    :variable (setq-variable form)
                    :value (lsb-form (value form))))
    (ast-tagbody
     (lsb-tagbody form))
    (ast-the
     (make-instance 'ast-the
                    :type (the-type form)
                    :value (lsb-form (value form))))
    (ast-unwind-protect
     (lsb-unwind-protect form))
    (ast-call
     (make-instance 'ast-call
                    :name (name form)
                    :arguments (mapcar #'lsb-form (arguments form))))
    (ast-jump-table
     (make-instance 'ast-jump-table
                    :value (lsb-form (value form))
                    :targets (mapcar #'lsb-form (targets form))))
    (lexical-variable form)
    (lambda-information
     (lsb-lambda form))))

(defun lsb-find-b-or-t-binding (info)
  "Locate the BLOCK or TAGBODY binding info on the *SPECIAL-BINDINGS* stack."
  (do ((i *special-bindings* (cdr i)))
      ((and (eql (first (first i)) :block-or-tagbody)
            (eql (second (first i)) info))
       i)
    (assert i () "Could not find block/tagbody information?")))

(defun lsb-unwind-to (location)
  "Generate code to unwind to a given location on the binding stack."
  (do ((current *special-bindings* (cdr current))
       (forms '()))
      ((eql current location)
       (nreverse forms))
    (assert current () "Ran off the end of the binding stack?")
    (let ((binding (first current)))
      (ecase (first binding)
        (:block-or-tagbody
         (when (third binding)
           (push (make-instance 'ast-call
                                :name 'sys.int::%%disestablish-block-or-tagbody
                                :arguments '())
                 forms)))
        (:special
         (push (make-instance 'ast-call
                                :name 'sys.int::%%unbind
                                :arguments '())
               forms))
        (:unwind-protect
         (push (make-instance 'ast-call
                                :name 'sys.int::%%disestablish-unwind-protect
                                :arguments '())
               forms))))))

(defun lsb-block (form)
  (let ((*special-bindings* *special-bindings*)
        (info (info form)))
    (push (list :block-or-tagbody
                info
                (block-information-env-var info)
                (block-information-env-offset info))
          *special-bindings*)
    (cond
      ((block-information-env-var info)
       ;; Escaping block.
       (make-instance 'ast-block
                      :info info
                      :body (make-instance 'ast-progn
                                           :forms (list
                                                   ;; Must be inside the block, so the special stack pointer is saved correctly.
                                                   (make-instance 'ast-call
                                                                  :name 'sys.int::%%push-special-stack
                                                                  :arguments (list (block-information-env-var info)
                                                                                   (make-instance 'ast-quote
                                                                                                  :value (block-information-env-offset info))))
                                                   (make-instance 'ast-multiple-value-prog1
                                                                  :value-form (lsb-form (body form))
                                                                  :body (make-instance 'ast-call
                                                                                       :name 'sys.int::%%disestablish-block-or-tagbody
                                                                                       :arguments '()))))))
      (t ;; Local block.
       (make-instance 'ast-block
                      :info info
                      :body (lsb-form (body form)))))))

(defun lsb-go (form)
  (let ((tag (target form))
        (location (info form)))
    (cond ((eql (go-tag-tagbody tag) location)
           ;; Local GO, locate the matching TAGBODY and emit any unwind forms required.
           (make-instance 'ast-progn
                          :forms (append (lsb-unwind-to (lsb-find-b-or-t-binding location))
                                         (list (make-instance 'ast-go
                                                              :target tag
                                                              :info location)))))
          (t ;; Non-local GO, do the full unwind.
           (let ((info (make-instance 'lexical-variable
                                      :name (gensym "go-info")
                                      :definition-point *current-lambda*)))
             (make-instance 'ast-let
                            :bindings (list (list info (lsb-form location)))
                            :body (make-instance 'ast-progn
                                                 :forms (list
                                                         ;; Ensure it's still valid.
                                                         (make-instance 'ast-if
                                                                        :test info
                                                                        :then (make-instance 'ast-quote :value 'nil)
                                                                        :else (make-instance 'ast-call
                                                                                             :name 'sys.int::raise-bad-go-tag
                                                                                             :arguments (list (make-instance 'ast-quote :value (go-tag-name tag)))))
                                                         (make-instance 'ast-call
                                                                        :name 'sys.int::%%unwind-to
                                                                        :arguments (list (make-instance 'ast-call
                                                                                                        :name 'sys.int::%%tagbody-info-binding-stack-pointer
                                                                                                        :arguments (list info))))
                                                         (make-instance 'ast-go
                                                                        :target tag
                                                                        :info info)))))))))

(defun lsb-let (form)
  (let ((*special-bindings* *special-bindings*))
    (labels ((frob (bindings)
               (cond (bindings
                      (let ((binding (first bindings)))
                        (cond ((lexical-variable-p (first binding))
                               (make-instance 'ast-let
                                              :bindings (list (list (first binding) (lsb-form (second binding))))
                                              :body (frob (rest bindings))))
                              (t
                               (push (list :special (first binding))
                                     *special-bindings*)
                               (make-instance 'ast-progn
                                              :forms (list (make-instance 'ast-call
                                                                          :name 'sys.int::%%bind
                                                                          :arguments (list (make-instance 'ast-quote
                                                                                                          :value (first binding))
                                                                                           (lsb-form (second binding))))
                                                           (make-instance 'ast-multiple-value-prog1
                                                                          :value-form (frob (rest bindings))
                                                                          :body (make-instance 'ast-call
                                                                                               :name 'sys.int::%%unbind
                                                                                               :arguments '()))))))))
                     (t (lsb-form (body form))))))
      (frob (bindings form)))))

(defun lsb-return-from (form)
  (let ((tag (target form))
        (value-form (value form))
        (location (info form)))
    (cond ((not (eql tag location))
           ;; Non-local RETURN-FROM, do the full unwind.
           (let ((info (make-instance 'lexical-variable
                                      :name (gensym "return-from-info")
                                      :definition-point *current-lambda*)))
             (make-instance 'ast-let
                            :bindings (list (list info (lsb-form location)))
                            :body (make-instance 'ast-progn
                                                 :forms (list
                                                         (make-instance 'ast-if
                                                                        :test info
                                                                        :then (make-instance 'ast-quote :value 'nil)
                                                                        :else (make-instance 'ast-call
                                                                                             :name 'sys.int::raise-bad-block
                                                                                             :arguments (list (make-instance 'ast-quote
                                                                                                                             :value (lexical-variable-name tag)))))
                                                         (make-instance 'ast-return-from
                                                                        :target tag
                                                                        :value (make-instance 'ast-multiple-value-prog1
                                                                                              :value-form (lsb-form value-form)
                                                                                              :body (make-instance 'ast-call
                                                                                                                   :name 'sys.int::%%unwind-to
                                                                                                                   :arguments (list (make-instance 'ast-call
                                                                                                                                                   :name 'sys.int::%%block-info-binding-stack-pointer
                                                                                                                                                   :arguments (list info)))))
                                                                        :info info))))))
          (t
           ;; Local RETURN-FROM, locate the matching BLOCK and emit any unwind forms required.
           ;; Note: Unwinding one-past the location so as to pop the block as well.
           (make-instance 'ast-return-from
                          :target tag
                          :value (make-instance 'ast-multiple-value-prog1
                                                :value-form (lsb-form value-form)
                                                :body (make-instance 'ast-progn
                                                                     :forms (lsb-unwind-to (cdr (lsb-find-b-or-t-binding tag)))))
                          :info location)))))

(defun lsb-tagbody (form)
  (let ((*special-bindings* *special-bindings*)
        (info (info form)))
    (flet ((frob-tagbody ()
             (make-instance 'ast-tagbody
                            :info (info form)
                            :statements (mapcar (lambda (x)
                                                  (if (go-tag-p x)
                                                      x
                                                      (lsb-form x)))
                                                (statements form)))))
      (push (list :block-or-tagbody
                  info
                  (tagbody-information-env-var info)
                  (tagbody-information-env-offset info))
            *special-bindings*)
      (cond
        ((tagbody-information-env-var info)
         ;; Escaping TAGBODY.
         (make-instance 'ast-progn
                        :forms (list
                                ;; Must be outside the tagbody, so the special stack pointer is saved correctly.
                                (make-instance 'ast-call
                                               :name 'sys.int::%%push-special-stack
                                               :arguments (list (tagbody-information-env-var info)
                                                                (make-instance 'ast-quote
                                                                               :value (tagbody-information-env-offset info))))
                                (frob-tagbody)
                                (make-instance 'ast-call
                                               :name 'sys.int::%%disestablish-block-or-tagbody
                                               :arguments '())
                                (make-instance 'ast-quote :value 'nil))))
        (t ;; Local TAGBODY.
         (frob-tagbody))))))

(defun lsb-unwind-protect (form)
  (let ((*special-bindings* (cons (list :unwind-protect) *special-bindings*))
        (protected-form (protected-form form))
        (cleanup-function (cleanup-function form)))
    ;; The cleanup function must either be a naked lambda or a
    ;; call to make-closure with a known lambda.
    (assert (or (lambda-information-p cleanup-function)
                (and (typep cleanup-function 'ast-call)
                     (eql (name cleanup-function) 'sys.int::make-closure)
                     (= (list-length (arguments cleanup-function)) 2)
                     (lambda-information-p (first (arguments cleanup-function))))))
    (when (not (lambda-information-p cleanup-function))
      ;; cleanup closures use the unwind-protect call protocol (code in r13, env in rbx, no closure indirection).
      (setf (getf (lambda-information-plist (first (arguments cleanup-function))) 'unwind-protect-cleanup) t))
    (make-instance 'ast-progn
                   :forms (list
                           (make-instance 'ast-call
                                          :name 'sys.int::%%push-special-stack
                                          :arguments (cond
                                                       ((lambda-information-p cleanup-function)
                                                        (list (lsb-form cleanup-function)
                                                              (make-instance 'ast-quote :value 0)))
                                                       (t
                                                        (setf (getf (lambda-information-plist (first (arguments cleanup-function))) 'unwind-protect-cleanup) t)
                                                        (list (lsb-form (first (arguments cleanup-function)))
                                                              (lsb-form (second (arguments cleanup-function)))))))
                           (make-instance 'ast-multiple-value-prog1
                                          :value-form (lsb-form protected-form)
                                          :body (make-instance 'ast-call
                                                               :name 'sys.int::%%disestablish-unwind-protect
                                                               :arguments '()))))))
