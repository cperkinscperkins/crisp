;;; src/hoist/source-mode.lisp -- Endeavour 190: --hoist-kernel=source, the parts BOTH hoisters share.
;;;
;;; A source-mode launcher EMBEDS the .crisp text and the compile flags, compiles them at run time
;;; through the compile API (c-api/include/crisp.h), and takes every argument slot -- and its launch
;;; geometry and scratch sizes -- from the API's answers instead of values baked in at hoist time.
;;; Each hoister writes its ordinary launcher and then rewrites it (hoist-l0 %hk-rewrite-arg-indices,
;;; hoist-cuda %cuda-hk-rewrite); what is common lives here: the arguments crisp-compile passes, the
;;; embedded sources, the API compile + slot map, and the per-parameter slot roles.

(in-package :crisp.hoist)

(defvar *hoist-kernel-source-mode* nil
  "Endeavour 190: T when crisp-compile asked for --hoist-kernel=source.")

(defvar *hoist-kernel-sources* nil
  "Endeavour 190: the .crisp paths to embed, in compile order (from --kernel-source=).")

(defvar *hoist-kernel-flags* nil
  "Endeavour 190: the compile flags to embed, in order (from --kernel-flag=).")

(defvar *hoist-current-kernel-name* nil
  "Endeavour 190: the kernel being emitted, for the source-mode slot map.")

(defvar *hoist-current-signature* nil
  "Endeavour 190: (DECLARED-SIG FULL-SIG ALIASES RECORDS) of the kernel being emitted.")

(defvar *hoist-current-dispatch-info* nil
  "Endeavour 190: the dispatch-info plist of the kernel being emitted (for the launch-object check).")

(defun %hk-extract-args (args)
  "Splits the endeavour-190 arguments out of ARGS, setting the *hoist-kernel-...* specials.
   Returns the remaining arguments (for the hoister's own argument parsing)."
  (loop for a in args
        if (string= a "--hoist-kernel=source")
          do (setf *hoist-kernel-source-mode* t)
        else if (uiop:string-prefix-p "--kernel-source=" a)
          do (setf *hoist-kernel-sources* (append *hoist-kernel-sources* (list (subseq a (length "--kernel-source=")))))
        else if (uiop:string-prefix-p "--kernel-flag=" a)
          do (setf *hoist-kernel-flags* (append *hoist-kernel-flags* (list (subseq a (length "--kernel-flag=")))))
        else collect a))

(defun %hk-c-string (s)
  "S as a C string literal."
  (with-output-to-string (out)
    (write-char #\" out)
    (loop for ch across s
          do (case ch
               (#\\ (write-string "\\\\" out))
               (#\" (write-string "\\\"" out))
               (#\Newline (write-string "\\n" out))
               (#\Return (write-string "\\r" out))
               (#\Tab (write-string "\\t" out))
               (t (write-char ch out))))
    (write-char #\" out)))

(defun %hk-source-literal (text)
  "TEXT as a C++ raw string literal (an escaped ordinary literal if TEXT contains the delimiter)."
  (if (search ")CRISP_SOURCE\"" text)
      (%hk-c-string text)
      (format nil "R\"CRISP_SOURCE(~a)CRISP_SOURCE\"" text)))

(defun %hk-emit-embedded-sources (stream &optional emit-wrappers)
  "File-scope C++: the compile API header, then EMIT-WRAPPERS (a function of STREAM: the hoister's own
   recording wrappers, if any), then the embedded sources and the flags."
  (format stream "// Endeavour 190 (--hoist-kernel=source): the kernel is compiled at RUN time from this source,~%")
  (format stream "// through the Crisp compile API.  Link with crisp.dll / libcrisp.so; it finds crisp-compile beside itself.~%")
  (format stream "#include \"crisp.h\"~%~%")
  (when emit-wrappers (funcall emit-wrappers stream))
  (format stream "static const char* const crisp_kernel_sources[] = {~%")
  (dolist (path *hoist-kernel-sources*)
    (format stream "    ~a,~%" (%hk-source-literal (uiop:read-file-string path))))
  (format stream "};~%")
  (format stream "static const char* const crisp_kernel_source_names[] = {~%")
  (dolist (path *hoist-kernel-sources*)
    (format stream "    ~a,~%" (%hk-c-string (file-namestring path))))
  (format stream "};~%")
  (format stream "static const size_t crisp_kernel_source_count = ~d;~%" (length *hoist-kernel-sources*))
  (format stream "static const char* const crisp_kernel_flags[] = {~%")
  (dolist (f *hoist-kernel-flags*)
    (format stream "    ~a,~%" (%hk-c-string f)))
  (format stream "    nullptr~%};~%")
  (format stream "static const size_t crisp_kernel_flag_count = ~d;~%~%" (length *hoist-kernel-flags*)))

(defun %hk-param-roles (param aliases records)
  "The (BAKED-SLOT ROLE AXIS) of each slot of PARAM, by the layout both hoisters emit against (a
   cell: pointer, byte size, offset; a tensor: pointer, byte size, offsets, strides, extents, length)
   -- the layout src/api.lisp %api-roles describes, which is the point: the launcher asks the API and
   the run proves the two agree."
  (let* ((type (resolve-type-alias (getf param :type) aliases))
         (range (getf param :range))
         (first-slot (first range))
         (last-slot (second range))
         ;; implicit (scratch) params carry no :rank -- only their type form says it
         (rank (or (getf param :rank)
                   (and (tensor-type-p type)
                        (let ((head (symbol-name (first type))))
                          (cond ((string-equal head "VECTOR") 1)
                                ((string-equal head "MATRIX") 2)
                                ((integerp (third type)) (third type))))))))
    (cond
      (rank
       (append (list (list first-slot "CRISP_ROLE_POINTER" 0) (list (+ first-slot 1) "CRISP_ROLE_BYTE_SIZE" 0))
               (loop for k below rank collect (list (+ first-slot 2 k) "CRISP_ROLE_OFFSET" k))
               (loop for k below rank collect (list (+ first-slot 2 rank k) "CRISP_ROLE_STRIDE" k))
               (loop for k below rank collect (list (+ first-slot 2 (* 2 rank) k) "CRISP_ROLE_EXTENT" k))
               (list (list (+ first-slot 2 (* 3 rank)) "CRISP_ROLE_LENGTH" 0))))
      ((cell-type-p type)
       (list (list first-slot "CRISP_ROLE_POINTER" 0) (list (+ first-slot 1) "CRISP_ROLE_BYTE_SIZE" 0)
             (list (+ first-slot 2) "CRISP_ROLE_OFFSET" 0)))
      ((or (record-type-p type records) (struct-type-p type))
       (loop for slot from first-slot to last-slot for i from 0 collect (list slot "CRISP_ROLE_FIELD" i)))
      (t (list (list first-slot "CRISP_ROLE_VALUE" 0))))))

(defun %hk-slot-total ()
  "The number of argument slots the current kernel's launcher was generated for."
  (destructuring-bind (declared full aliases records) *hoist-current-signature*
    (declare (ignore declared aliases records))
    (or (loop for p in full for r = (getf p :range) when (consp r) maximize (1+ (second r))) 0)))

(defun %hk-emit-compile-and-slot-map (stream target binary-line)
  "main()-scope C++: compile the embedded source through the API for TARGET (\"spv\" / \"ptx\"), then
   BINARY-LINE (the hoister's line handing crisp_bin / crisp_bin_size to its runtime), find this
   launcher's kernel in the result, and build crisp_slot[] -- baked argument index -> the slot the
   API says -- for EVERY parameter, declared and implicit."
  (destructuring-bind (declared full aliases records) *hoist-current-signature*
    (declare (ignore declared))
    (let ((total (%hk-slot-total)))
      (format stream "    // Endeavour 190: compile the embedded Crisp source NOW, through the compile API~%")
      (format stream "    crisp_context* crisp_ctx = nullptr;~%")
      (format stream "    if (crisp_context_create(~a, &crisp_ctx) != CRISP_OK) {~%" (%hk-c-string target))
      (format stream "        std::cerr << \"ERROR: crisp_context_create failed\" << std::endl;~%")
      (format stream "        return 1;~%")
      (format stream "    }~%")
      (format stream "    crisp_set_flags(crisp_ctx, crisp_kernel_flags, crisp_kernel_flag_count);~%")
      (format stream "    for (size_t i = 0; i < crisp_kernel_source_count; i++)~%")
      (format stream "        crisp_add_source(crisp_ctx, crisp_kernel_sources[i], crisp_kernel_source_names[i]);~%")
      (format stream "    crisp_status crisp_st = crisp_compile(crisp_ctx);~%")
      (format stream "    if (crisp_st != CRISP_OK) {~%")
      (format stream "        std::cerr << \"ERROR: crisp_compile: \" << crisp_status_string(crisp_st) << std::endl~%")
      (format stream "                  << crisp_diagnostics_text(crisp_ctx);~%")
      (format stream "        return 1;~%")
      (format stream "    }~%")
      (format stream "    const void* crisp_bin = nullptr;~%")
      (format stream "    size_t crisp_bin_size = 0;~%")
      (format stream "    crisp_module_binary(crisp_ctx, 0, &crisp_bin, &crisp_bin_size);~%")
      (format stream "~a~%" binary-line)
      (format stream "    std::cout << \"Kernel compiled at run time through the Crisp compile API (\" << crisp_bin_size << \" bytes)\" << std::endl;~%~%")
      (format stream "    // ... and ask it where each argument goes~%")
      (format stream "    size_t crisp_k = (size_t)-1;~%")
      (format stream "    for (size_t i = 0; i < crisp_kernel_count(crisp_ctx, 0); i++)~%")
      (format stream "        if (std::strcmp(crisp_kernel_name(crisp_ctx, 0, i), ~a) == 0) crisp_k = i;~%"
              (%hk-c-string *hoist-current-kernel-name*))
      (format stream "    if (crisp_k == (size_t)-1) {~%")
      (format stream "        std::cerr << \"ERROR: the compile API produced no kernel ~a\" << std::endl;~%" *hoist-current-kernel-name*)
      (format stream "        return 1;~%")
      (format stream "    }~%")
      (format stream "    auto crisp_param = [&](const char* name) -> size_t {~%")
      (format stream "        for (size_t p = 0; p < crisp_param_count(crisp_ctx, 0, crisp_k); p++)~%")
      (format stream "            if (std::strcmp(crisp_param_name(crisp_ctx, 0, crisp_k, p), name) == 0) return p;~%")
      (format stream "        return (size_t)-1;~%")
      (format stream "    };~%")
      (format stream "    if (crisp_slot_count(crisp_ctx, 0, crisp_k) != ~d) {~%" total)
      (format stream "        std::cerr << \"ERROR: the compile API reports \" << crisp_slot_count(crisp_ctx, 0, crisp_k)~%")
      (format stream "                  << \" argument slots; this launcher was generated for ~d\" << std::endl;~%" total)
      (format stream "        return 1;~%")
      (format stream "    }~%")
      (format stream "    size_t crisp_slot[~d];~%" (max total 1))
      (format stream "    for (size_t i = 0; i < ~d; i++) crisp_slot[i] = i;   // any slot no parameter claims~%" total)
      (let ((mapped 0))
        (dolist (p full)
          (when (consp (getf p :range))
            (dolist (e (%hk-param-roles p aliases records))
              (destructuring-bind (baked role axis) e
                (incf mapped)
                (format stream "    crisp_slot[~d] = crisp_param_slot(crisp_ctx, 0, crisp_k, crisp_param(~a), ~a, ~d);~%"
                        baked (%hk-c-string (getf p :name)) role axis)))))
        (format stream "    for (size_t i = 0; i < ~d; i++) {~%" total)
        (format stream "        if (crisp_slot[i] == CRISP_NO_SLOT) {~%")
        (format stream "            std::cerr << \"ERROR: the compile API has no slot for hoisted argument \" << i << std::endl;~%")
        (format stream "            return 1;~%")
        (format stream "        }~%")
        (format stream "        if (crisp_slot[i] != i)~%")
        (format stream "            std::cout << \"NOTE: the compile API moved argument \" << i << \" to slot \" << crisp_slot[i] << std::endl;~%")
        (format stream "    }~%")
        (format stream "    std::cout << \"Argument slots from the compile API: ~d of ~d\" << std::endl;~%~%" mapped total)))))

(defun %hk-strided-occupancy-p ()
  "T when the current kernel's group count comes from the occupancy path (:strategy :strided with
   no tile grid) -- the test both hoisters' dispatch emitters make -- so the launcher has its
   resident-group capacity to hand the API."
  (let* ((di *hoist-current-dispatch-info*)
         (decl (or (getf di :global-size) (getf di :num-groups)))
         (rest (when decl (cdr decl)))
         (strategy (when rest (getf rest :strategy)))
         (name (and strategy (symbol-name strategy))))
    (and name (string-equal name "STRIDED")
         (not (and (getf rest :tile-shape) (getf rest :derive-from))))))

(defun %hk-emit-launch-inputs (s value-array)
  "C++ that feeds the launch object crisp_L the values this launcher ACTUALLY passed: each declared
   tensor's extents and each declared scalar, read back from VALUE-ARRAY (indexed by API slot)."
  (format s "        const size_t crisp_np = crisp_param_count(crisp_ctx, 0, crisp_k);~%")
  (format s "        for (size_t p = 0; p < crisp_np; p++) {   // inputs: what this launcher passed~%")
  (format s "            if (crisp_param_purpose(crisp_ctx, 0, crisp_k, p) != CRISP_PURPOSE_DECLARED) continue;~%")
  (format s "            crisp_param_kind kind = crisp_param_kind_of(crisp_ctx, 0, crisp_k, p);~%")
  (format s "            if (kind == CRISP_PARAM_TENSOR) {~%")
  (format s "                for (uint32_t a = 0; a < crisp_param_rank(crisp_ctx, 0, crisp_k, p); a++) {~%")
  (format s "                    size_t sl = crisp_param_slot(crisp_ctx, 0, crisp_k, p, CRISP_ROLE_EXTENT, a);~%")
  (format s "                    if (sl < 1024) crisp_launch_set_extent(crisp_L, p, a, ~a[sl]);~%" value-array)
  (format s "                }~%")
  (format s "            } else if (kind == CRISP_PARAM_SCALAR) {~%")
  (format s "                size_t sl = crisp_param_slot(crisp_ctx, 0, crisp_k, p, CRISP_ROLE_VALUE, 0);~%")
  (format s "                if (sl < 1024) crisp_launch_set_scalar(crisp_L, p, ~a[sl]);~%" value-array)
  (format s "            }~%")
  (format s "        }~%"))

(defun %hk-emit-scratch-checks (s value-array &key shared-offsets)
  "C++ comparing every scratch parameter's BYTE_SIZE slot value (from VALUE-ARRAY, by API slot) with
   crisp_launch_param_bytes -- and, with SHARED-OFFSETS (PTX), each local scratch's POINTER slot
   value with crisp_launch_param_shared_offset.  Sets crisp_bad; counts crisp_scratch."
  (format s "        size_t crisp_scratch = 0;~%")
  (format s "        for (size_t p = 0; p < crisp_np; p++) {~%")
  (format s "            if (crisp_param_purpose(crisp_ctx, 0, crisp_k, p) != CRISP_PURPOSE_SCRATCH) continue;~%")
  (format s "            size_t sl = crisp_param_slot(crisp_ctx, 0, crisp_k, p, CRISP_ROLE_BYTE_SIZE, 0);~%")
  (format s "            uint64_t api_bytes = crisp_launch_param_bytes(crisp_L, p);~%")
  (format s "            crisp_scratch++;~%")
  (format s "            if (sl >= 1024 || ~a[sl] != api_bytes) {~%" value-array)
  (format s "                std::cerr << \"MISMATCH: scratch \" << crisp_param_name(crisp_ctx, 0, crisp_k, p) << \" bytes: API \"~%")
  (format s "                          << api_bytes << \", launcher \" << (sl < 1024 ? ~a[sl] : 0) << std::endl;~%" value-array)
  (format s "                crisp_bad = 1;~%")
  (format s "            }~%")
  (when shared-offsets
    (format s "            uint64_t api_off = crisp_launch_param_shared_offset(crisp_L, p);~%")
    (format s "            if (api_off != CRISP_NO_SHARED_OFFSET) {~%")
    (format s "                size_t ps = crisp_param_slot(crisp_ctx, 0, crisp_k, p, CRISP_ROLE_POINTER, 0);~%")
    (format s "                if (ps >= 1024 || ~a[ps] != api_off) {~%" value-array)
    (format s "                    std::cerr << \"MISMATCH: scratch \" << crisp_param_name(crisp_ctx, 0, crisp_k, p)~%")
    (format s "                              << \" shared offset: API \" << api_off << \", launcher \" << (ps < 1024 ? ~a[ps] : 0) << std::endl;~%" value-array)
    (format s "                    crisp_bad = 1;~%")
    (format s "                }~%")
    (format s "            }~%"))
  (format s "        }~%"))

(defun %hk-replace-all (text old new)
  "TEXT with every OLD replaced by NEW."
  (with-output-to-string (out)
    (loop with start = 0
          for hit = (search old text :start2 start)
          do (write-string text out :start start :end (or hit (length text)))
             (if hit
                 (progn (write-string new out) (setf start (+ hit (length old))))
                 (return)))))
