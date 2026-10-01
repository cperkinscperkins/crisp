;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)

;; tests/run-specs.lisp  (new -- endeavour 176)
(defun %vad-find-simd-width (forms)
  "The :SIMD-WIDTH recorded anywhere in the metacrisp FORMS (the hardware-profile section), or NIL."
  (labels ((walk (x)
             (cond ((and (consp x) (consp (cdr x)) (eq (car x) :simd-width) (integerp (cadr x)))
                    (return-from %vad-find-simd-width (cadr x)))
                   ((consp x) (walk (car x)) (walk (cdr x))))))
    (walk forms)
    nil))

;; tests/run-specs.lisp  (new -- endeavour 176)
(defun %vad-resolve-symbolic-size (size kern forms)
  "Endeavour 176.  SIZE (an implicit param's :size-expr) as an element COUNT.  An integer is returned as
   is.  A symbolic size -- implicit reduction scratch is :match-num-warps-per-workgroup (local sweep) or
   :match-workgroup-size (last-man's global partials) -- is resolved from KERN's declared local size and
   the hardware profile's SIMD width found in FORMS, by the same rules as the hoisters
   (%l0-scratch-symbolic-expr): ceiling division for warps, warp width 32 when no profile is recorded."
  (if (not (keywordp size))
      size
      (let* ((ls (getf kern :local-size))            ; (local-size :set-to N) or (local-size :set-to (A B))
             (n (and (consp ls) (third ls)))
             (n (cond ((integerp n) n)
                      ((and (consp n) (eq (car n) 'quote)) (reduce #'* (second n)))
                      ((and (consp n) (every #'integerp n)) (reduce #'* n))
                      (t nil)))
             (warp (or (%vad-find-simd-width forms) 32)))
        (unless n
          (error "%vad-resolve-symbolic-size: symbolic :size-expr ~s needs a compile-time (local-size :set-to N); kernel declares ~s"
                 size ls))
        (cond ((string-equal (symbol-name size) "MATCH-WORKGROUP-SIZE") n)
              ((string-equal (symbol-name size) "MATCH-NUM-WARPS-PER-WORKGROUP") (ceiling n warp))
              (t (error "%vad-resolve-symbolic-size: unsupported symbolic :size-expr ~s" size))))))

;; tests/run-specs.lisp  (176: only change -- a symbolic :size-expr is resolved to a count)
(defun %vad-read-implicit-params (file kernel-name &key grad)
  "Reads the forward or backward kernel's metacrisp file for FILE and
   extracts its :implicit-params, returning a list of plists each
       (:base START :n-elements N :elem-bytes BYTES :arg-width 6)
   for use by VERIFY-AUTODIFF.  Returns NIL if the file is missing, has
   no :kernels block, or the matching kernel has no implicit params.

   The compiler emits implicit-params for local-mem scratch tiles -- in
   the forward they come from a (let ((tile (make-scratch-vector ...))))
   that participates in load-tile-at / store-tile-at; in the
   backward the AD pass adds a paired tile_ADJ shadow for each.  Each
   implicit param's :range pair gives its inclusive arg-slot span and
   :size-expr is the element count of the underlying tensor.  Element
   type comes from the second sub-form of :type, e.g. (tensor float 1
   ...) -> float -> 4 bytes."
  (let* ((meta-path (%vad-metacrisp-path file kernel-name :grad grad))
         (wanted-name (if grad
                          (format nil "~a_grad" kernel-name)
                          kernel-name)))
    (unless (probe-file meta-path)
      (return-from %vad-read-implicit-params nil))
    (let ((forms (with-open-file (s meta-path :direction :input)
                   (loop for f = (read s nil :eof)
                         until (eq f :eof) collect f))))
      (dolist (form forms)
        (when (and (consp form) (eq (first form) :kernels))
          (dolist (kern (rest form))
            (when (and (eq (first kern) :name)
                       (string-equal (second kern) wanted-name))
              (let ((implicit (getf kern :implicit-params)))
                (return-from %vad-read-implicit-params
                  (loop for p in implicit
                        ;; Endeavor 147: a :kind :tensor-map implicit param (the
                        ;; CUtensorMap descriptor Crisp mints for a :block TMA
                        ;; kernel) carries NO :type key.  The old code read
                        ;; (second (getf p :type)) -> NIL and fell into the
                        ;; unsupported-elem-type ERROR below, so a TMA spec
                        ;; CRASHED here rather than reaching the device.  Pass it
                        ;; through with its own shape instead; its physical width
                        ;; is 1 (a single descriptor pointer), which keeps every
                        ;; downstream arg-base offset correct.
                        when (eq (getf p :kind) :tensor-map)
                          collect (let ((range (getf p :range)))
                                    (list :kind :tensor-map
                                          :name (getf p :name)
                                          :describes (getf p :describes)
                                          :element-type (getf p :element-type)
                                          :rank (getf p :rank)
                                          :box-dims (getf p :box-dims)
                                          :layout (or (getf p :layout) :row-major)
                                          :swizzle (or (getf p :swizzle) :none)
                                          :base (first range)
                                          :arg-width (1+ (- (second range) (first range)))))
                        else
                        collect
                        (let* ((range (getf p :range))
                               (size (getf p :size-expr))
                               (type-spec (getf p :type))
                               (elem-type (second type-spec))
                               (elem-bytes
                                 (case elem-type
                                   ((float)  4)
                                   ((half bfloat16) 2)
                                   ((double) 8)
                                   ;; Endeavour 175: a UINT scratch cell.  grid-reduce-last-man!
                                   ;; needs two -- the global ticket counter and the local election
                                   ;; flag -- so any differentiated kernel using it hit the error
                                   ;; below.  4 bytes, matching Crisp's 32-bit uint.
                                   ((uint) 4)
                                   ((int ulong long) 8)
                                   (t (error "%vad-read-implicit-params: unsupported elem-type ~A in ~A"
                                             elem-type type-spec))))
                               ;; Endeavor 145 (P6): a 2-D scratch tile's :size-expr is a
                               ;; LIST (ROWS COLS), not an integer.  Carry :rows / :cols
                               ;; through for the 9-arg matrix binding and make
                               ;; :n-elements their product so every consumer still sees
                               ;; an element count.
                               (dims (and (listp size) size)))
                          (list :base (first range)
                                ;; 176: a SYMBOLIC size (implicit reduction scratch) is resolved to a
                                ;; count from the kernel's local size and the profile's SIMD width.
                                :n-elements (if dims (reduce #'* dims) (%vad-resolve-symbolic-size size kern forms))
                                :rows (and dims (first dims))
                                :cols (and dims (second dims))
                                ;; 147/08: a RING is a rank-3 scratch tensor whose
                                ;; :size-expr is (SLOTS ROWS COLS), so :rows/:cols
                                ;; describe it wrongly and its descriptor is 12 slots
                                ;; wide.  Carry the whole dims list so the binder can
                                ;; build a rank-N tensor record instead of guessing.
                                :dims dims
                                :elem-bytes elem-bytes
                                ;; BUG 084: the address space was read from the metacrisp and
                                ;; then dropped here, so every implicit scratch param reached
                                ;; the binder looking local and was bound as SLM.  A :global
                                ;; buffer needs a real device allocation; binding it as shared
                                ;; local memory hands the kernel a bogus addrspace(1) pointer
                                ;; and the first write ends in DEVICE_LOST.  Defaulting to
                                ;; :local preserves the old behaviour for everything else.
                                :address-space (or (getf p :address-space) :local)
                                :arg-width (1+ (- (second range) (first range)))))))))))))))
