;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)



;;; ======================================================================
;;; Endeavour 163 — VERIFY-AUTODIFF could not read a 16-BIT kernel's implicit params.
;;;
;;;     FAIL (Runner error: %vad-read-implicit-params: unsupported elem-type HALF in (TENSOR ...))
;;;
;;; The elem-bytes table knew float/double/int/ulong/long and nothing 16-bit, so the reader
;;; ERRORED on the first `half` scratch tile.  A 16-bit MMA backward is made almost entirely of
;;; those (the staged operands, their _ADJ pairs, and the backward's transposed temporaries), so
;;; no 16-bit kernel could reach the device at all.
;;;
;;; This is the same SHAPE of harness gap endeavour 145 P6 fixed when it taught VERIFY-AUTODIFF
;;; about 2-D matrices: the mechanism was fine, the runner just could not describe the operand.
;;; ======================================================================

;; tests/run-specs.lisp  (REPLACES %vad-read-implicit-params -- 163, 16-bit elem types)
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
                                :n-elements (if dims (reduce #'* dims) size)
                                :rows (and dims (first dims))
                                :cols (and dims (second dims))
                                ;; 147/08: a RING is a rank-3 scratch tensor whose
                                ;; :size-expr is (SLOTS ROWS COLS), so :rows/:cols
                                ;; describe it wrongly and its descriptor is 12 slots
                                ;; wide.  Carry the whole dims list so the binder can
                                ;; build a rank-N tensor record instead of guessing.
                                :dims dims
                                :elem-bytes elem-bytes
                                :arg-width (1+ (- (second range) (first range)))))))))))))))

