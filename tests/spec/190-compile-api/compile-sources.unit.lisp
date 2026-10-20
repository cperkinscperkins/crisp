;; Endeavour 190 (compile API), B1 -- the Lisp core behind the C API.
;;
;; COMPILE-SOURCES takes source STRINGS + flags + one target and returns everything the C side
;; will hand out (c-api/include/crisp.h), as a plain nested plist:
;;
;;   (:status :ok | :compile-error | :invalid-argument | :internal-error
;;    :diagnostics ((:severity :error|:warning|:note :message "..." :file "x.crisp" :line 0 :column 0) ...)
;;    :modules ((:binary #(octets...)
;;               :kernels ((:name "k_one"
;;                          :slots  ((:type :pointer :size 8 :address-space :global) (:type :ulong :size 8) ...)
;;                          :params ((:name "a" :kind :tensor :direction :in :element-type :float :rank 1
;;                                    :address-space :global
;;                                    :roles ((:pointer 0 0) (:byte-size 0 1) (:offset 0 2) ...)) ...)) ...)))))
;;
;; :roles entries are (ROLE AXIS SLOT): the slot layout lives in Lisp; the C side only looks it up.
;; It must never quit the image, never write to *standard-output* (that will be the server's
;; protocol channel), and leave no files behind.

(in-package :cl-user)

(defpackage :crisp.test.compile-api
  (:use :cl :parachute))

(in-package :crisp.test.compile-api)

;;; ------------------------------------------------------------------------------------------------
;;; Fixtures -- source TEXT, so its symbols are read by the compiler in :crisp-language, never here.
;;; ------------------------------------------------------------------------------------------------

(defparameter +two-kernels+
  "(def-type fvec (vector float :address-space :global :align :compact))
(def-kernel k_one (A &out B)
  (declare #'(fvec &out fvec => nil))
  (set! (~ B 0) (* (~ A 0) 2.0)))
(def-kernel k_two (A &out B)
  (declare #'(fvec &out fvec => nil))
  (set! (~ B 0) (+ (~ A 0) 1.0)))
")

(defparameter +scalar-param+
  "(def-type fvec (vector float :address-space :global :align :compact))
(def-kernel k_scale (s &out B)
  (declare #'(float &out fvec => nil))
  (set! (~ B 0) s))
")

(defparameter +types-only+
  "(def-type fvec (vector float :address-space :global :align :compact))
")

(defparameter +kernel-using-types+
  "(def-kernel k_use (A &out B)
  (declare #'(fvec &out fvec => nil))
  (set! (~ B 0) (~ A 0)))
")

(defparameter +vec-sq-lit+
  "(def-type in-vec (vector float :address-space :global :align :compact))
(def-type out-c  (cell float :address-space :global))
(def-kernel vec_sq_lit (A &out C)
  (declare #'(in-vec &out out-c))
  (set! (~ C) (* (~ A 2) (~ A 2))))
")

(defparameter +undefined-variable+
  "(def-type fvec (vector float :address-space :global :align :compact))
(def-kernel k_bad (A &out B)
  (declare #'(fvec &out fvec => nil))
  (set! (~ B 0) no_such_variable))
")

(defparameter +unbalanced+
  "(def-kernel k_open (A &out B)
  (declare #'(fvec &out fvec => nil))
")

;;; ------------------------------------------------------------------------------------------------
;;; Helpers
;;; ------------------------------------------------------------------------------------------------

(defparameter *190-temp-root* (merge-pathnames "put_temp_files_here/190/api-tmp/" (uiop:getcwd))
  "Where these tests point the API's temp directories, so 'no files left behind' is checkable.")

(defun compile-quietly (sources &key (target "spv") flags)
  "COMPILE-SOURCES with stdout captured.  Returns (values RESULT STDOUT-TEXT)."
  (ensure-directories-exist *190-temp-root*)
  (let* ((result nil)
         (out (with-output-to-string (*standard-output*)
                (let ((crisp.main::*api-temp-root* *190-temp-root*))
                  (setf result (crisp.main::compile-sources sources :target target :flags flags))))))
    (values result out)))

(defun modules (r) (getf r :modules))
(defun kernels (r) (getf (first (modules r)) :kernels))
(defun kernel (r name) (find name (kernels r) :key (lambda (k) (getf k :name)) :test #'string=))
(defun param (k name) (find name (getf k :params) :key (lambda (p) (getf p :name)) :test #'string=))
(defun role-slot (p role axis)
  (third (find-if (lambda (e) (and (eq (first e) role) (= (second e) axis))) (getf p :roles))))
(defun errors-of (r) (remove :error (getf r :diagnostics) :key (lambda (d) (getf d :severity)) :test-not #'eq))
(defun binary-text (r) (map 'string #'code-char (getf (first (modules r)) :binary)))
(defun temp-root-empty-p ()
  (null (append (uiop:directory-files *190-temp-root*) (uiop:subdirectories *190-temp-root*))))

;;; ------------------------------------------------------------------------------------------------
;;; Tests
;;; ------------------------------------------------------------------------------------------------

(define-test compile-api)

(define-test (compile-api spv-two-kernels)
  (multiple-value-bind (r out) (compile-quietly (list (cons +two-kernels+ "two.crisp")))
    (is eq :ok (getf r :status))
    (is equal "" out "nothing on stdout")
    (is = 1 (length (modules r)) "v1: exactly one module")
    (let ((bin (getf (first (modules r)) :binary)))
      (true (> (length bin) 20))
      (is equalp #(3 2 35 7) (subseq bin 0 4) "SPIR-V magic 0x07230203, little-endian"))
    (is equal '("k_one" "k_two") (mapcar (lambda (k) (getf k :name)) (kernels r)))
    (true (temp-root-empty-p) "no files left behind")))

(define-test (compile-api ptx-two-kernels)
  (let ((r (compile-quietly (list (cons +two-kernels+ "two.crisp")) :target "ptx")))
    (is eq :ok (getf r :status))
    (true (search ".entry k_one" (binary-text r)))
    (true (search ".entry k_two" (binary-text r)))
    (true (temp-root-empty-p))))

(define-test (compile-api tensor-params-and-slots)
  (let* ((r (compile-quietly (list (cons +two-kernels+ "two.crisp"))))
         (k (kernel r "k_one"))
         (a (param k "a"))
         (b (param k "b")))
    (true k)
    (is equal '("a" "b") (mapcar (lambda (p) (getf p :name)) (getf k :params)))
    (is eq :tensor (getf a :kind))
    (is eq :in (getf a :direction))
    (is eq :out (getf b :direction))
    (is eq :float (getf a :element-type))
    (is = 1 (getf a :rank))
    (is eq :global (getf a :address-space))
    ;; two rank-1 tensors: 3N+3 = 6 slots each
    (is = 12 (length (getf k :slots)))
    (let ((s0 (first (getf k :slots))) (s1 (second (getf k :slots))))
      (is eq :pointer (getf s0 :type))
      (is = 8 (getf s0 :size))
      (is eq :global (getf s0 :address-space))
      (is eq :ulong (getf s1 :type))
      (is = 8 (getf s1 :size)))
    ;; PTR, BYTE_SIZE, OFF_0, STR_0, EXT_0, LENGTH  (hoist-l0/main.lisp ~L1387)
    (is = 0 (role-slot a :pointer 0))
    (is = 1 (role-slot a :byte-size 0))
    (is = 2 (role-slot a :offset 0))
    (is = 3 (role-slot a :stride 0))
    (is = 4 (role-slot a :extent 0))
    (is = 5 (role-slot a :length 0))
    (is = 6 (role-slot b :pointer 0))
    (is = 11 (role-slot b :length 0))
    (false (role-slot a :stride 1) "no axis 1 on a rank-1 tensor")))

(define-test (compile-api scalar-param)
  (let* ((r (compile-quietly (list (cons +scalar-param+ "scale.crisp"))))
         (k (kernel r "k_scale"))
         (s (param k "s")))
    (is eq :ok (getf r :status))
    (is eq :scalar (getf s :kind))
    (is eq :float (getf s :element-type))
    (is = 0 (getf s :rank))
    (is = 0 (role-slot s :value 0))
    (let ((slot0 (first (getf k :slots))))
      (is eq :float (getf slot0 :type))
      (is = 4 (getf slot0 :size))
      (false (getf slot0 :address-space)))))

(define-test (compile-api multiple-sources)
  (let ((r (compile-quietly (list (cons +types-only+ "types.crisp")
                                  (cons +kernel-using-types+ "kern.crisp")))))
    (is eq :ok (getf r :status))
    (true (kernel r "k_use"))))

(define-test (compile-api compile-error)
  (multiple-value-bind (r out) (compile-quietly (list (cons +undefined-variable+ "broken.crisp")))
    (is eq :compile-error (getf r :status))
    (is equal "" out "errors go to diagnostics, not stdout")
    (false (modules r))
    (true (errors-of r))
    (let ((d (first (errors-of r))))
      (true (plusp (length (getf d :message))))
      (is equal "broken.crisp" (getf d :file)))
    (true (temp-root-empty-p))))

(define-test (compile-api unbalanced-source)
  (let ((r (compile-quietly (list (cons +unbalanced+ "open.crisp")))))
    (is eq :compile-error (getf r :status))
    (true (errors-of r))))

(define-test (compile-api recovers-after-error)
  (compile-quietly (list (cons +undefined-variable+ "broken.crisp")))
  (let ((r (compile-quietly (list (cons +two-kernels+ "two.crisp")))))
    (is eq :ok (getf r :status))
    (is = 2 (length (kernels r)))))

(define-test (compile-api rejected-flags)
  (dolist (flag '("--hoist=l0" "--metadata" "--ir-target=ptx" "--log-level=debug"
                  "--no-such-flag" "--math-precision=sloppy"))
    (let ((r (compile-quietly (list (cons +two-kernels+ "two.crisp")) :flags (list flag))))
      (is eq :invalid-argument (getf r :status) "~a is rejected" flag)
      (true (some (lambda (d) (search flag (getf d :message))) (getf r :diagnostics))
            "the diagnostic names ~a" flag))))

(define-test (compile-api bad-target)
  (let ((r (compile-quietly (list (cons +two-kernels+ "two.crisp")) :target "gpu")))
    (is eq :invalid-argument (getf r :status))))

(define-test (compile-api accepted-flags)
  (let ((r (compile-quietly (list (cons +two-kernels+ "two.crisp"))
                            :flags '("--math-precision=fast" "--runtime-checks" "--single-pass"))))
    (is eq :ok (getf r :status))
    (is = 2 (length (kernels r)))))

;; S2: with --differentiate the module holds the primal AND the _grad kernel, and both are
;; described (today's .metacrisp describes only the _grad one -- F4).
(define-test (compile-api differentiate-describes-both-kernels)
  (let ((r (compile-quietly (list (cons +vec-sq-lit+ "vsl.crisp")) :flags '("--differentiate"))))
    (is eq :ok (getf r :status))
    (true (kernel r "vec_sq_lit"))
    (true (kernel r "vec_sq_lit_grad"))))

;;; Gate: a quiet `is` failure does not abort the load, so the runner would call this file PASS.
(let* ((report (test 'compile-api))
       (failures (parachute:results-with-status :failed report)))
  (when failures
    (error "compile-api: ~d check(s) failed" (length failures))))
