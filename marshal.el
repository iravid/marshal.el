;;; marshal.el --- eieio extension for automatic (un)marshalling

;; Copyright (C) 2015  Yann Hodique

;; Author: Yann Hodique <hodiquey@vmware.com>
;; Keywords: eieio
;; Version: 0.1
;; URL: https://github.com/sigma/marshal.el
;; Package-Requires: ((eieio "1.4"))

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:

;; Inspired by Go tagged structs. An 'assoc driver is provided, but
;; implementing others just requires to inherit from `marshal-driver'. It's
;; also possible to maintain a private drivers "namespace", by providing
;; the :marshal-base-cls option to `marshal-defclass'. This is particularly
;; useful to maintain different "views" of the same object (potentially using
;; the same driver) without having to register many drivers in the
;; global space.

;; Examples:

;; 1. Regular use:

;; (marshal-defclass plop ()
;;   ((foo :initarg :foo :type string :marshal ((assoc . field_foo)))
;;    (bar :initarg :bar :type integer :marshal ((assoc . field_bar)))
;;    (baz :initarg :baz :type integer :marshal ((assoc . field_baz)))))

;; (marshal-defclass plopi ()
;;   ((alpha :marshal ((assoc . field_alpha)))
;;    (beta :type plop :marshal ((assoc . field_beta)))))

;; (marshal (make-instance 'plop :foo "ok" :bar 42) 'assoc)
;; => '((field_bar . 42) (field_foo . "ok"))

;; (unmarshal 'plop '((field_foo . "plop") (field_bar . 0) (field_baz . 1)) 'assoc)
;; => '[object plop "plop" "plop" 0 1]

;; (marshal
;;  (unmarshal 'plopi '((field_alpha . 42)
;;                      (field_beta . ((field_foo . "plop")
;;                                     (field_bar . 0)
;;                                     (field_baz . 1)))) 'assoc)
;;  'assoc)
;; => '((field_beta (field_baz . 1) (field_bar . 0) (field_foo . "plop")) (field_alpha . 42))

;; 2. Namespaced:

;; (defclass my/marshal-base (marshal-base)
;;   nil)

;; (marshal-register-driver 'my/marshal-base 'full 'marshal-driver-assoc)
;; (marshal-register-driver 'my/marshal-base 'short 'marshal-driver-assoc)

;; (marshal-defclass plop ()
;;   ((foo :initarg :foo :type string :marshal ((full . field_foo) (short . field_foo)))
;;    (bar :initarg :bar :type integer :marshal ((full . field_bar)))
;;    (baz :initarg :baz :type integer :marshal ((full . field_baz))))
;;   :marshal-base-cls my/marshal-base)

;; (marshal (make-instance 'plop :foo "ok" :bar 42) 'full)
;; => ((field_bar . 42) (field_foo . "ok"))

;; (marshal (make-instance 'plop :foo "ok" :bar 42) 'short)
;; => ((field_foo . "ok"))

;; (unmarshal 'plop '((field_foo . "plop") (field_bar . 0) (field_baz . 1)) 'full)
;; => [object plop "plop" "plop" 0 1]

;; (unmarshal 'plop '((field_foo . "plop") (field_bar . 0) (field_baz . 1)) 'short)
;; => [object plop "plop" "plop" unbound unbound]

;;; Code:

(require 'eieio)

(defclass marshal-driver ()
  ())

(defmethod marshal-write ((obj marshal-driver) tag value))

(defmethod marshal-read ((obj marshal-driver) tag blob))

(defclass marshal-driver-assoc (marshal-driver)
  ((result :initarg :result :initform nil)))

(defmethod marshal-write ((obj marshal-driver-assoc) tag value)
  (object-add-to-list obj :result (cons tag value))
  (oref obj :result))

(defmethod marshal-read ((obj marshal-driver-assoc) tag blob)
  (cdr (assoc tag blob)))

(defclass marshal-base ()
  ((-marshal-info :allocation :class :initform nil :protection :protected)
   (-type-info :allocation :class :initform nil :protection :protected)
   (drivers :allocation :class :initform nil)))

(defmethod marshal-register-driver :static ((obj marshal-base) type driver)
  (let ((existing (assoc type (oref-default obj drivers))))
    (if existing
        (setcdr existing driver)
      (oset-default obj drivers
                    (cons (cons type driver)
                          (oref-default obj drivers))))
    nil))

(marshal-register-driver 'marshal-base 'assoc 'marshal-driver-assoc)

(defmethod marshal-get-driver ((obj marshal-base) type)
  (let ((cls (or (cdr (assoc type (oref obj drivers)))
                 'marshal-driver)))
    (make-instance cls)))

(defmethod marshal ((obj marshal-base) type)
  (let ((driver (marshal-get-driver obj type))
        (marshal-info (cdr (assoc type (oref obj -marshal-info))))
        res)
    (when marshal-info
      (dolist (s (object-slots obj))
        (let ((tag (cdr (assoc s marshal-info))))
          (when (and tag
                     (slot-boundp obj s))
            
            (setq res (marshal-write driver tag (marshal
                                               (eieio-oref obj s)
                                               type)))))))
    res))

(defmethod marshal (obj type)
  obj)

(defmethod unmarshal--obj ((obj marshal-base) blob type)
  (let ((driver (marshal-get-driver obj type))
        (marshal-info (cdr (assoc type (oref obj -marshal-info)))))
    (when marshal-info
      (dolist (s (object-slots obj))
        (let ((tag (cdr (assoc s marshal-info))))
          (when tag
            (eieio-oset obj s
                        (unmarshal
                         (cdr (assoc s (oref obj -type-info)))
                         (marshal-read driver tag blob)
                         type))))))
    obj))

(defmethod unmarshal :static ((obj marshal-base) blob type)
  (let ((obj (or (and (object-p obj) obj)
                 (make-instance obj))))
    (unmarshal--obj obj blob type)))

(defmethod unmarshal ((obj nil) blob type)
  blob)

(defun marshal--transpose-alist2 (l)
  (let (res
        (rows l))
    (while rows
      (let* ((row (car rows))
             (x (car row))
             (cols (cdr row)))
        (while cols
          (let* ((col (car cols))
                 (y (car col))
                 (z (cdr col))
                 (target (or (assoc y res)
                             (let ((p (cons y nil)))
                               (setq res (push p res))
                               p))))
            (setcdr target (cons (cons x z) (cdr target))))
          (setq cols (cdr cols))))
      (setq rows (cdr rows)))
    res))

(defmacro marshal-defclass (name superclass slots &rest options-and-doc)
  (let ((marshal-info (marshal--transpose-alist2
                       (mapcar (lambda (s)
                                 (let ((name (car s)))
                                   (let ((marshal (plist-get (cdr s) :marshal)))
                                     (when marshal
                                       (cons name marshal)))))
                               slots)))
        (type-info (mapcar (lambda (s)
                             (let ((name (car s)))
                               (let ((type (plist-get (cdr s) :type)))
                                 (when type
                                   (cons name type)))))
                           slots))
        (base-cls (or (plist-get (if (stringp (car options-and-doc))
                                     (cdr options-and-doc)
                                     options-and-doc)
                                 :marshal-base-cls)
                      'marshal-base)))
    `(progn
       (defclass ,name (,@superclass ,base-cls)
         ((-marshal-info :allocation :class
                         :initform ,marshal-info :protection :protected)
          (-type-info :allocation :class
                      :initform ,type-info :protection :protected)
          ,@slots)
         ,@options-and-doc))))

(provide 'marshal)
;;; marshal.el ends here
