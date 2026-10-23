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
(defun kernels-without-binary (r) (kernels r))
(defun binary-text (r)(map 'string #'code-char (getf (first (modules r)) :binary)))
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
    ;; PTX's .metacrisp records a pointer slot as ULONG (.param .b64); the API still says pointer
    (let ((s0 (first (getf (kernel r "k_one") :slots))))
      (is eq :pointer (getf s0 :type))
      (is eq :global (getf s0 :address-space)))
    (true (temp-root-empty-p))))

;; A long-lived server compiles many times in ONE image; the second compile must look like the first.
(define-test (compile-api repeat-compiles-are-identical)
  (let ((first-r (compile-quietly (list (cons +two-kernels+ "two.crisp"))))
        (ptx-r (compile-quietly (list (cons +two-kernels+ "two.crisp")) :target "ptx"))
        (again (compile-quietly (list (cons +two-kernels+ "two.crisp")))))
    (false (getf ptx-r :diagnostics) "no 'redefining ... DEFMACRO' noise")
    (false (getf again :diagnostics))
    (is equalp (getf (first (modules first-r)) :binary) (getf (first (modules again)) :binary))
    (is equal (kernels-without-binary first-r) (kernels-without-binary again))))

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
    (is eq :compact (getf a :layout) "fvec is :align :compact: the kernel ignores offsets and strides")
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
    (false (getf s :layout) "layout is a tensor-only fact")
    (is = 0 (role-slot s :value 0))
    (let ((slot0 (first (getf k :slots))))
      (is eq :float (getf slot0 :type))
      (is = 4 (getf slot0 :size))
      (false (getf slot0 :address-space)))))

(defparameter +strided-matrix+
  "(def-type smat (matrix float :address-space :global :align :strided))
(def-type out-c (cell float :address-space :global))
(def-kernel k_mat (M &out C)
  (declare #'(smat &out out-c))
  (set! (~ C) (~ M 1 2)))
")

(define-test (compile-api strided-matrix-roles)
  (let* ((r (compile-quietly (list (cons +strided-matrix+ "mat.crisp"))))
         (m (param (kernel r "k_mat") "m")))
    (is eq :ok (getf r :status))
    (is eq :strided (getf m :layout))
    (is = 2 (getf m :rank))
    ;; rank 2: PTR, BYTE_SIZE, OFF0, OFF1, STR0, STR1, EXT0, EXT1, LENGTH = 3N+3 = 9 slots
    (is equal '(0 1 2 3 4 5 6 7 8)
        (list (role-slot m :pointer 0) (role-slot m :byte-size 0)
              (role-slot m :offset 0) (role-slot m :offset 1)
              (role-slot m :stride 0) (role-slot m :stride 1)
              (role-slot m :extent 0) (role-slot m :extent 1)
              (role-slot m :length 0)))
    (is = 12 (length (getf (kernel r "k_mat") :slots)) "9 for M + 3 for the cell C")))

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
    (is equal '("vec_sq_lit" "vec_sq_lit_grad") (mapcar (lambda (k) (getf k :name)) (kernels r))
        "each forward kernel, then its _grad")
    (true (temp-root-empty-p))))

;; The primal described by a --differentiate compile is the SAME as a plain compile's.
(define-test (compile-api differentiate-primal-matches-plain)
  (let* ((plain (kernel (compile-quietly (list (cons +vec-sq-lit+ "vsl.crisp"))) "vec_sq_lit"))
         (diff  (kernel (compile-quietly (list (cons +vec-sq-lit+ "vsl.crisp")) :flags '("--differentiate"))
                        "vec_sq_lit")))
    (true plain)
    (true diff)
    (is equal (getf plain :slots) (getf diff :slots))
    (is equal (getf plain :params) (getf diff :params))))

;; Adjoint pairing (A3 item 6): explicit, not left to the caller's reading of names.
(define-test (compile-api differentiate-adjoint-pairing)
  (let* ((r (compile-quietly (list (cons +vec-sq-lit+ "vsl.crisp")) :flags '("--differentiate")))
         (fwd (kernel r "vec_sq_lit"))
         (bwd (kernel r "vec_sq_lit_grad")))
    (false (getf fwd :grad-of))
    (is equal "vec_sq_lit" (getf bwd :grad-of))
    (is equal '("a" "c" "c_grad" "a_grad") (mapcar (lambda (p) (getf p :name)) (getf bwd :params)))
    (false (getf (param bwd "a") :adjoint-of))
    (false (getf (param bwd "c") :adjoint-of))
    (is equal "c" (getf (param bwd "c_grad") :adjoint-of))
    (is equal "a" (getf (param bwd "a_grad") :adjoint-of))
    (is eq :in (getf (param bwd "c_grad") :direction) "the incoming gradient")
    (is eq :out (getf (param bwd "a_grad") :direction) "the computed gradient")
    (false (getf (param fwd "a") :adjoint-of))))

;; A user's OWN parameter named <x>_grad is not an adjoint; its adjoint is <x>_grad_grad.
(defparameter +user-named-grad+
  "(def-type fvec (vector float :address-space :global :align :compact))
(def-type out-c (cell float :address-space :global))
(def-kernel k_ug (A w_grad &out C)
  (declare #'(fvec float &out out-c))
  (set! (~ C) (* (~ A 0) w_grad)))
")

(define-test (compile-api differentiate-user-named-grad-param)
  (let* ((r (compile-quietly (list (cons +user-named-grad+ "ug.crisp")) :flags '("--differentiate")))
         (bwd (kernel r "k_ug_grad")))
    (is eq :ok (getf r :status))
    (true bwd)
    (false (getf (param bwd "w_grad") :adjoint-of) "the user's own w_grad is an input, not an adjoint")
    (is equal "w_grad" (getf (param bwd "w_grad_grad") :adjoint-of))
    ;; a SCALAR's gradient comes back through memory: an :out cell
    (is eq :cell (getf (param bwd "w_grad_grad") :kind))
    (is eq :out (getf (param bwd "w_grad_grad") :direction))))

;; The fast-vs-preserve warning only when preserve was ASKED for (crisp-compile warns on every
;; --math-precision=fast, because :preserve is merely its default).
(define-test (compile-api fast-precision-warning-only-on-explicit-preserve)
  (flet ((warnings (flags)
           (remove :warning (getf (compile-quietly (list (cons +two-kernels+ "two.crisp")) :flags flags) :diagnostics)
                   :key (lambda (d) (getf d :severity)) :test-not #'eq)))
    (false (warnings '("--math-precision=fast")))
    (true (warnings '("--math-precision=fast" "--denormal-handling=preserve")))
    (false (warnings '("--math-precision=fast" "--denormal-handling=ftz")))))

;;; ------------------------------------------------------------------------------------------------
;;; Item 2, step 1 (A9, A11): IMPLICIT parameters join the parameter list, with a purpose.
;;; The kernel is a real spec's source, read from disk: four scratch params (a local flag cell, a
;;; global counter cell, a global vector of 4, a local vector sized one-per-warp) + one declared.
;;; ------------------------------------------------------------------------------------------------

(defun grid-reduce-kernel ()
  (kernel (compile-quietly
           (list (cons (uiop:read-file-string "tests/spec/175-reductions/25-grid-reduce-last-man-metal.crisp")
                       "grid.crisp"))
           :flags '("--hardware-profile=bmg"))
          "grid_reduce_last_man"))

(defun param-starting-with (k prefix)
  (find-if (lambda (p) (alexandria:starts-with-subseq prefix (getf p :name))) (getf k :params)))

(define-test (compile-api implicit-params-join-the-list)
  (let* ((k (grid-reduce-kernel))
         (params (getf k :params)))
    (true k)
    (is = 5 (length params) "4 scratch + 1 declared")
    (is equal '(0 3 6 12 18) (mapcar (lambda (p) (role-slot p :pointer 0)) params) "in slot order")
    (is equal '(:scratch :scratch :scratch :scratch :declared) (mapcar (lambda (p) (getf p :purpose)) params))
    (is equal "out" (getf (fifth params) :name))
    ;; every physical slot belongs to exactly one parameter now
    (let ((owned (sort (loop for p in params append (mapcar #'third (getf p :roles))) #'<)))
      (is equal (loop for i below (length (getf k :slots)) collect i) owned))))

(define-test (compile-api implicit-param-facts)
  (let* ((k (grid-reduce-kernel))
         (flag (param-starting-with k "flag_"))
         (ctr (param-starting-with k "ctr_"))
         (gv (param-starting-with k "gv_"))
         (sv (param-starting-with k "sv_"))
         (out (param k "out")))
    ;; kinds, element types, address spaces -- from the type form, since scratch has no :rank
    (is eq :cell (getf flag :kind))
    (is eq :uint (getf flag :element-type))
    (is eq :local (getf flag :address-space))
    (is eq :global (getf ctr :address-space))
    (is eq :tensor (getf gv :kind))
    (is = 1 (getf gv :rank))
    (is eq :float (getf gv :element-type))
    (is eq :compact (getf gv :layout))
    (is eq :local (getf sv :address-space))
    (is = 17 (role-slot sv :length 0) "rank-1 tensor at 12: PTR BYTE OFF STR EXT LEN")
    ;; direction means nothing for scratch
    (false (getf sv :direction))
    (is eq :out (getf out :direction))
    ;; A11: GLOBAL scratch is zeroed before EVERY launch; local scratch cannot be; declared never
    (true (getf ctr :zero-before-launch))
    (true (getf gv :zero-before-launch))
    (false (getf flag :zero-before-launch))
    (false (getf sv :zero-before-launch))
    (false (getf out :zero-before-launch))
    ;; the size rule rides along for the launch object (step 2)
    (is equal '(:elements 1) (getf ctr :size))
    (is equal '(:elements 4) (getf gv :size))
    (is equal '(:rule :match-num-warps-per-workgroup) (getf sv :size))
    (false (getf out :size))
    ;; PTX would record the scratch pointer slots as ULONG; the roles still make them pointers
    (is eq :pointer (getf (nth 12 (getf k :slots)) :type))
    (is eq :local (getf (nth 12 (getf k :slots)) :address-space))))

(define-test (compile-api implicit-params-ptx-pointer-slots)
  (let ((k (kernel (compile-quietly
                    (list (cons (uiop:read-file-string "tests/spec/175-reductions/25-grid-reduce-last-man-metal.crisp")
                                "grid.crisp"))
                    :target "ptx")
                   "grid_reduce_last_man")))
    (true k)
    (is equal '(:pointer :pointer :pointer :pointer :pointer)
        (mapcar (lambda (s) (getf (nth s (getf k :slots)) :type)) '(0 3 6 12 18)))))

;;; ------------------------------------------------------------------------------------------------
;;; Item 2, step 2: each kernel's GEOMETRY declarations, normalised for the C launch object (A10).
;;; Read from the .metacrisp (so a compiler-INFERRED :tile-shape is seen too).  Names in
;;; :derive-from / :set-to become indices into the kernel's parameter list.
;;; ------------------------------------------------------------------------------------------------

(defun strategy-kernel (spec &key flags (kernel-index 0))
  "The KERNEL-INDEX'th kernel of tests/spec/089-strategy/SPEC.crisp, compiled through the API."
  (let ((r (compile-quietly (list (cons (uiop:read-file-string (format nil "tests/spec/089-strategy/~a.crisp" spec))
                                        (format nil "~a.crisp" spec)))
                            :flags flags)))
    (unless (eq (getf r :status) :ok)
      (format *error-output* "~&strategy-kernel ~a: ~s~%" spec (getf r :diagnostics)))
    (nth kernel-index (kernels r))))

(defun param-index (k name)
  (position name (getf k :params) :key (lambda (p) (getf p :name)) :test #'string-equal))

(define-test (compile-api geometry-set-to-and-local)
  (let ((g (getf (strategy-kernel "13-hoist-local-global-exact") :geometry)))
    (is eq :global-size (getf g :dispatch))
    (is equal '(1024) (getf g :set-to))
    (is equal '(64 1) (getf g :local)))
  (let* ((k (strategy-kernel "11-hoist-set-to-dims"))
         (g (getf k :geometry)))
    ;; :set-to may name scalar params: (:param INDEX)
    (is equal (list (list :param (param-index k "width")) (list :param (param-index k "height")))
        (getf g :set-to))
    (is equal '(1 1) (getf g :local) "no local-size: 1")))

(define-test (compile-api geometry-derive-from)
  (let* ((k (strategy-kernel "12-hoist-one-thread-per"))
         (g (getf k :geometry)))
    (is eq :one-thread-per (getf g :strategy))
    (is equal (list :scalars (param-index k "width") (param-index k "height")) (getf g :derive)))
  (let* ((k (strategy-kernel "22-derive-from-vector-one-thread-per"))
         (g (getf k :geometry)))
    (is equal (list :tensor (param-index k "input")) (getf g :derive) "a bare symbol: a tensor")
    (is equal '(256 1) (getf g :local))))

(define-test (compile-api geometry-strided-tile-occupancy)
  (let ((g (getf (strategy-kernel "23-strided-with-occupancy") :geometry)))
    (is eq :strided (getf g :strategy))
    (is = 0.5 (getf g :occupancy)))
  (let ((g (getf (strategy-kernel "15-hoist-exact-tiled") :geometry)))
    (is eq :exact (getf g :strategy))
    (is equal '(16 16) (getf g :tile-shape))
    (is equal '(16 16) (getf g :local)))
  (let ((g (getf (strategy-kernel "24-tile-shape-inferred") :geometry)))
    (true (getf g :tile-shape) "the compiler INFERRED it; the .metacrisp carries it"))
  (let ((g (getf (strategy-kernel "14-hoist-strided") :geometry)))
    (is eq :num-groups (getf g :dispatch) "num-groups stands in when there is no global-size")))

(define-test (compile-api geometry-clusters)
  (flet ((cluster-kernel (spec)
           (first (kernels (compile-quietly
                            (list (cons (uiop:read-file-string (format nil "tests/spec/152-DSMEM-Cluster/~a.crisp" spec))
                                        (format nil "~a.crisp" spec)))
                            :target "ptx" :flags '("--ir-target-arch=sm_90"))))))
    (let ((g (getf (cluster-kernel "04-cluster-size-on-metal") :geometry)))
      (is equal '(2 1) (subseq (getf g :cluster) 0 2) "(cluster-size :set-to (2 1))")
      (false (getf g :cluster-reach)))
    (let ((g (getf (cluster-kernel "26-cluster-reach-refuses-padding") :geometry)))
      (is equal '(2 2) (subseq (getf g :cluster) 0 2))
      (true (getf g :cluster-reach) "it multicasts / uses a cluster barrier: padding is unsafe"))))

;; BUG 066 on PTX (fixed in endeavour 190): a _grad kernel inherits its forward kernel's launch
;; geometry on EVERY backend -- it used to happen only inside the SPIR-V subgroup emitter.
(define-test (compile-api grad-kernel-inherits-geometry-on-every-backend)
  (dolist (target '("ptx" "spv"))
    (let* ((r (compile-quietly (list (cons (uiop:read-file-string "c-api/examples/square_scale.crisp") "ss.crisp"))
                               :target target :flags '("--differentiate")))
           (fwd (getf (kernel r "square_scale") :geometry))
           (bwd (getf (kernel r "square_scale_grad") :geometry)))
      (is eq :ok (getf r :status))
      (is eq :global-size (getf bwd :dispatch) "~a: the _grad kernel declares a launch" target)
      (is equal (getf fwd :local) (getf bwd :local) "~a: same workgroup size as the forward kernel" target)
      (is eq (getf fwd :strategy) (getf bwd :strategy) "~a: same strategy" target))))

(define-test (compile-api geometry-undeclared-and-warp)
  (let ((k (kernel (compile-quietly (list (cons +two-kernels+ "two.crisp"))) "k_one")))
    (false (getf (getf k :geometry) :dispatch) "no global-size / num-groups")
    (is equal '(1 1) (getf (getf k :geometry) :local))
    (false (getf k :warp-size) "no hardware profile: the launch object falls back to 32"))
  (let ((k (grid-reduce-kernel)))
    (true (integerp (getf k :warp-size)) "--hardware-profile=bmg carries the SIMD width")))

;;; ------------------------------------------------------------------------------------------------
;;; The compile server's protocol (src/api.lisp, "The compile server"), round-tripped through files.
;;; ------------------------------------------------------------------------------------------------

(defparameter *190-proto-dir* (merge-pathnames "put_temp_files_here/190/proto/" (uiop:getcwd)))

(defun serve-through-files (requests-writer)
  "Writes a request stream with REQUESTS-WRITER (a function of an octet output stream), runs
   serve-requests over it, and returns the response as a list of (TAG . PAYLOAD-OCTETS)."
  (ensure-directories-exist *190-proto-dir*)
  (let ((req (merge-pathnames "req.bin" *190-proto-dir*))
        (resp (merge-pathnames "resp.bin" *190-proto-dir*)))
    (with-open-file (o req :direction :output :element-type '(unsigned-byte 8) :if-exists :supersede)
      (funcall requests-writer o))
    (with-open-file (i req :element-type '(unsigned-byte 8))
      (with-open-file (o resp :direction :output :element-type '(unsigned-byte 8) :if-exists :supersede)
        (let ((crisp.main::*api-temp-root* *190-temp-root*))
          (crisp.main::serve-requests i o))))
    (with-open-file (i resp :element-type '(unsigned-byte 8))
      (loop for (tag payload) = (multiple-value-list (crisp.main::%proto-read-record i))
            while tag collect (cons tag payload)))))

(defun write-request (o target flags sources)
  (crisp.main::%proto-write-record o "target" target)
  (dolist (f flags) (crisp.main::%proto-write-record o "flag" f))
  (loop for (text . name) in sources
        do (when name (crisp.main::%proto-write-record o "source-name" name))
           (crisp.main::%proto-write-record o "source" text))
  (crisp.main::%proto-write-record o "end" ""))

(defun records-text (records tag)
  (loop for (tg . p) in records when (string= tg tag) collect (sb-ext:octets-to-string p :external-format :utf-8)))

(define-test (compile-api protocol-round-trip)
  (let ((recs (serve-through-files
               (lambda (o)
                 (write-request o "spv" '() (list (cons +two-kernels+ "two.crisp")))
                 ;; a SECOND request on the same stream: the server answers both, in order
                 (write-request o "ptx" '("--no-such-flag") (list (cons +two-kernels+ "two.crisp")))))))
    (is equal '("ok" "invalid-argument") (records-text recs "status"))
    (is equal '("k_one" "k_two") (records-text recs "kernel.name"))
    (is = 2 (count "end" recs :key #'car :test #'string=))
    (let ((bin (cdr (find "module.binary" recs :key #'car :test #'string=))))
      (is equalp #(3 2 35 7) (subseq bin 0 4) "the binary survives the framing byte-for-byte"))
    (true (member "pointer 0 0" (records-text recs "role") :test #'string=))
    (true (some (lambda (m) (search "--no-such-flag" m)) (records-text recs "diag.message")))
    (true (temp-root-empty-p))))

(define-test (compile-api protocol-malformed-request)
  (let ((recs (serve-through-files
               (lambda (o) (write-sequence (sb-ext:string-to-octets "garbage!!" :external-format :utf-8) o)))))
    (is equal '("internal-error") (records-text recs "status"))
    (is = 1 (count "end" recs :key #'car :test #'string=))))

;;; Gate: a quiet `is` failure does not abort the load, so the runner would call this file PASS.
(let* ((report (test 'compile-api))
       (failures (parachute:results-with-status :failed report)))
  (when failures
    (error "compile-api: ~d check(s) failed" (length failures))))
