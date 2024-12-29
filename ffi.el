;;; ffi.el --- FFI for Emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2015-2017 Tom Tromey

;; Author: Tom Tromey <tom@tromey.com>
;; Package-Requires: ((emacs "25.1"))

;; This is is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This is an FFI for Emacs.  It is based on libffi and relies on the
;; dynamic module support in order to be loaded into Emacs.  It is
;; relatively full-featured, but for the time being low-level.

;;; Code:

(require 'cl-macs)

;; this module is located in the directory where ffi.el is located.
(module-load (expand-file-name
              "ffi-module.so"
              (file-name-directory (or load-file-name
                                       (buffer-file-name)))))


(gv-define-simple-setter ffi--mem-ref ffi--mem-set t)

(defmacro define-ffi-library (symbol name)
  "Create a pointer in SYMBOL that points to the c library of NAME.
NAME is a string that can be an absolute path or library name."
  (let ((library (cl-gensym))
        (docstring (format "Returns a pointer to the %s library." name)))
    (set library nil)
    `(defun ,symbol ()
       ,docstring
       (or ,library
           (setq ,library (ffi--dlopen ,name))))))

(defmacro define-ffi-function (name c-name return args library &optional docstring)
  "Create an Emacs function from a c-function.
NAME is a symbol for  the emacs function to create.
C-NAME is a string of the c-function to use.
RETURN is a type-keyword or (type-keyword docstring)
ARGS is a list of type-keyword or (type-keyword name &optional arg-docstring)
LIBRARY is a symbol usually defined by `define-ffi-library'
DOCSTRING is a string for the function to be created.

An overall docstring is created for the function from the arg and return docstrings.
"
  (declare (indent defun))
  ;; (let* (;; Turn variable references into actual types; while keeping
  ;;        ;; keywords the same.
  ;;        (arg-types (mapcar #'symbol-value arg-types))
  ;;        (arg-names (mapcar (lambda (_ignore) (cl-gensym)) arg-types))
  ;;        (arg-types (vconcat arg-types))
  ;;        (function (cl-gensym))
  ;;        (cif (ffi--prep-cif (symbol-value return-type) arg-types)))
  ;;   (set function nil)
  ;;   `(defun ,name (,@arg-names)
  ;;      (unless ,function
  ;;        (setq ,function (ffi--dlsym ,c-name (,library))))
  ;;      ;; FIXME do we even need a separate prep?
  ;;      (ffi--call ,cif ,function ,@arg-names)))
  (let* ((return-type (if (listp return)
                          (car return)
                        ;; anything else we use as is
			return))
	 (return-docstring (format "Returns: %s (%s)"
				   (if (listp return)
				       (cl-second return)
				     "")
				   return-type))
	 (arg-types (vconcat (mapcar (lambda (arg)
				       (if (listp arg)
                                           ;; assume list (type-keyword name &optional doc)
                                           (symbol-value (car arg))
					 (symbol-value arg)))
				     args)))
	 (arg-names (mapcar (lambda (arg)
			      (if (listp arg)
                                  ;; assume list (type-keyword name &optional doc)
				  (cl-second arg)
				(cl-gensym)))
			    args))
	 (arg-docstrings (mapcar (lambda (arg)
				   (cond
				    ((keywordp arg)
				     "")
				    ((and (listp arg) (= 3 (length arg)))
				     (cl-third arg))
				    (t "")))
				 args))
	 ;; Combine all the arg docstrings into one string
	 (arg-docstring  (mapconcat 'identity
		                    (cl-mapcar (lambda (name type arg-doc)
			                         (format "%s (%s) %s"
				                         (upcase (symbol-name name))
				                         type
				                         arg-doc))
			                       arg-names arg-types arg-docstrings)
		                    "\n"))
	 (function (cl-gensym))
	 (cif (ffi--prep-cif (symbol-value return-type) arg-types)))
    (set function nil)
    `(defun ,name (,@arg-names)
       ,(concat docstring "\n\n" arg-docstring "\n\n" return-docstring)
       (unless ,function
	 (setq ,function (ffi--dlsym ,c-name (,library))))
       ;; FIXME do we even need a separate prep?
       (ffi--call ,cif ,function ,@arg-names))))

(defun ffi-lambda (function-pointer return-type arg-types)
  (let ((cif (ffi--prep-cif return-type (vconcat arg-types))))
    (lambda (&rest args)             ; lame
      (apply #'ffi--call cif function-pointer args))))

(defsubst ffi--align (offset align)
  (+ offset (mod (- align (mod offset align)) align)))

(defun ffi--lay-out-struct (types)
  (let ((offset 0))
    (mapcar (lambda (this-type)
              (setf offset (ffi--align offset
                                       (ffi--type-alignment this-type)))
              (let ((here offset))
                (cl-incf offset (ffi--type-size this-type))
                here))
            types)))

(defun ffi--struct-union-helper (name slots definer-function layout-function)
  (cl-assert (symbolp name))
  (let* ((docstring (if (stringp (car slots))
                        (pop slots)))
         (conc-name (concat (symbol-name name) "-"))
         (result-forms ())
         (field-types (mapcar (lambda (slot)
                                (cl-assert (eq (cadr slot) :type))
                                (symbol-value (cl-caddr slot)))
                              slots))
         (the-type (apply definer-function field-types))
         (field-offsets (funcall layout-function field-types)))
    (push `(defvar ,name ,the-type ,docstring)
          result-forms)
    (cl-mapc
     (lambda (slot type offset)
       (let ((getter-name (intern (concat conc-name
                                          (symbol-name (car slot)))))
             (offsetter (if (> offset 0)
                            `(ffi-pointer+ object ,offset)
                          'object)))
         ;; One benefit of using defsubst here is that we don't have
         ;; to provide a GV setter.
         (push `(cl-defsubst ,getter-name (object)
                  (ffi--mem-ref ,offsetter ,type))
               result-forms)))
     slots field-types field-offsets)
    (cons 'progn (nreverse result-forms))))

(defmacro define-ffi-struct (name &rest slots)
  "Like a limited form of `cl-defstruct', but works with foreign objects.

NAME must be a symbol.
Each SLOT must be of the form `(SLOT-NAME :type TYPE)', where
SLOT-NAME is a symbol and TYPE is an FFI type descriptor."
  (declare (indent defun))
  (ffi--struct-union-helper name slots #'ffi--define-struct
                            #'ffi--lay-out-struct))

(defmacro define-ffi-union (name &rest slots)
  "Like a limited form of `cl-defstruct', but works with foreign objects.

NAME must be a symbol.
Each SLOT must be of the form `(SLOT-NAME :type TYPE)', where
SLOT-NAME is a symbol and TYPE is an FFI type descriptor."
  (declare (indent defun))
  (ffi--struct-union-helper name slots #'ffi--define-union
                            (lambda (types)
                              (make-list (length types) 0))))

(defmacro define-ffi-array (name type length &optional docstring)
  ;; This is a hack until libffi gives us direct support.
  (declare (indent defun))
  (let ((type-description
         (apply #'ffi--define-struct
                (make-list (eval length) (symbol-value type)))))
    `(defvar ,name ,type-description ,docstring)))

(defsubst ffi-aref (array type index)
  (ffi--mem-ref (ffi-pointer+ array (* index (ffi--type-size type))) type))

(defmacro with-ffi-temporary (binding &rest body)
  (declare (indent defun))
  `(let ((,(car binding) (ffi-allocate ,@(cdr binding))))
     (unwind-protect
         (progn ,@body)
       (ffi-free ,(car binding)))))

(defmacro with-ffi-temporaries (bindings &rest body)
  (declare (indent defun))
  (let ((first-binding (car bindings))
        (rest-bindings (cdr bindings)))
    (if rest-bindings
        `(with-ffi-temporary ,first-binding
           (with-ffi-temporaries ,rest-bindings
             ,@body))
      `(with-ffi-temporary ,first-binding ,@body))))

(defmacro with-ffi-string (binding &rest body)
  (declare (indent defun))
  `(let ((,(car binding) (ffi-make-c-string ,@(cdr binding))))
     (unwind-protect
         (progn ,@body)
       (ffi-free ,(car binding)))))

(defmacro with-ffi-strings (bindings &rest body)
  (declare (indent defun))
  (let ((first-binding (car bindings))
        (rest-bindings (cdr bindings)))
    (if rest-bindings
        `(with-ffi-string ,first-binding
           (with-ffi-strings ,rest-bindings
             ,@body))
      `(with-ffi-string ,first-binding ,@body))))

(provide 'ffi)

;;; ffi.el ends here
