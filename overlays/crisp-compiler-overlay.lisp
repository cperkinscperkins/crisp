(in-package :crisp.compiler)
;; src/metadata.lisp
;; Fixed to add :direction field to declared signature
(defun generate-declared-signature (sig &optional declared-params)
  (let ((declared-args nil)
        (current-phys-index 0)
        (out-mode nil) ;; Track if we've encountered &out
        (params-to-use (or declared-params (function-signature-parameters sig))))

    ;; Implicits come first, so offset the start index for declared params
    (dolist (p (function-signature-implicit-parameters sig))
      (incf current-phys-index (get-physical-width (parameter-def-type p))))

    (dolist (param-def params-to-use)
      (let* ((name (if (consp param-def) (car param-def) (parameter-def-name param-def)))
             (type (if (consp param-def) (cdr param-def) (parameter-def-type param-def))))

        ;; Check if this is the &out marker
        (if (and (symbolp name) (string-equal (symbol-name name) "&OUT"))
            (setf out-mode t) ;; Switch to output mode
            ;; Not &out marker, so it's a real parameter
            (let* ((width (get-physical-width type))
                   (start current-phys-index)
                   (end (+ start (max 0 (1- width))))
                   (entry (list :name (string-downcase (symbol-name name)))))

              ;; Add type
              (setf entry (append entry (list :type (strip-package-qualifiers type))))

              ;; Add direction (:in or :out)
              (setf entry (append entry (list :direction (if out-mode :out :in))))

              ;; Add storage handle specific fields (address-space, access)
              (when (%storage-handle-type-p type)
                    (let* ((canonical (canonicalize-type-specifier type))
                           (as (if (consp canonical)
                                   (let ((found (member :address-space canonical)))
                                     (if found (second found) :global))
                                   :global))
                           (acc (if (consp canonical)
                                    (let ((found (member :access canonical)))
                                      (if found (second found) :read-write))
                                    :read-write)))
                      (setf entry (append entry (list :address-space as :access acc)))))

              ;; Add range
              (setf entry (append entry (list :range (list start end))))
              (push entry declared-args)
              (incf current-phys-index width)))))
    (nreverse declared-args)))
