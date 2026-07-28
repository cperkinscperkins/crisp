(in-package :crisp.hoist.l0)

;;; ===================================================================
;;; ENDEAVOR 144 Phase 4 Step 4 — ask IGC for the register allocation the
;;; compiler selected.
;;;
;;; MEASURED: all three BMG benchmark kernels were spilling (intel_prefetch 1792 B,
;;; chap0_sync 2560 B, chap1_async_linear 2752 B) purely because the generated launcher
;;; hardcoded `nullptr` for ze_module_desc_t.pBuildFlags, leaving IGC in its default
;;; 128-GRF mode for kernels that demand 256.  Passing `-ze-opt-large-register-file`
;;; takes spill to 0 on all three and runs 1.5-2.07x faster (24.01 vs 11.61 TFLOPS at
;;; 1024 on a B580), verified MMA_CORRECT.
;;;
;;; The compiler decides (it owns the register-demand model); the hoist only transcribes.
;;; The decision arrives as :selected-registers-per-thread inside the metacrisp's
;;; (:hardware-profile ...) form.
;;;
;;; NOTE FOR THE SRC PATCH — these two definitions belong in DIFFERENT files:
;;;   %l0-note-hardware-profile + parse-metacrisp-file  -> src/hoist/common.lisp
;;;   generate-module-loading                           -> src/hoist-l0/main.lisp
;;; They are together here only because overlays/hoist-common/ is not loaded by any build
;;; script, so the hoist-l0 overlay is the only late-binding hook that reaches both.
;;; ===================================================================

(defvar *l0-selected-registers-per-thread* nil
  "Endeavor 144 Phase 4: the per-thread register allocation the COMPILER selected for this
   module, read from the metacrisp's (:hardware-profile ... :selected-registers-per-thread N).
   NIL when no profile was active or no kernel needed more than the default allocation.
   Consumed by generate-module-loading to set ze_module_desc_t.pBuildFlags.")

(defvar *l0-register-modes* nil
  "Endeavor 144 Phase 4: the profile's selectable :max-registers-per-thread modes (a list),
   so the hoist can tell whether the selected allocation IS the default (emit nothing) or a
   larger mode (emit the IGC flag).")

;; src/hoist/common.lisp
(in-package :crisp.hoist)

(defun parse-metacrisp-file (filepath)
  "Parse a .metacrisp file and return the data structure.

   Endeavor 144 Phase 4: also latches the active profile's register-allocation decision
   into crisp.hoist.l0::*l0-selected-registers-per-thread* / *l0-register-modes*, so the
   L0 module build can request it.  Latching here (rather than threading the profile
   through generate-l0-launcher) keeps the change to two small functions."
  (with-open-file (stream filepath :direction :input)
    (let ((aliases '())
          (structs '())
          (records '())
          (kernels '())
          (hardware-profile nil))
      ;; Read all forms from the file
      (loop for form = (read stream nil :eof)
            until (eq form :eof)
            do (cond
                ((and (consp form) (eq (first form) :aliases))
                  (setf aliases (or (rest form) '())))
                ((and (consp form) (eq (first form) :structs))
                  (setf structs (or (rest form) '())))
                ((and (consp form) (eq (first form) :records))
                  (setf records (or (rest form) '())))
                ((and (consp form) (eq (first form) :kernels))
                  (setf kernels (or (rest form) '())))
                ;; Endeavor 130 Phase 5: the active hardware profile (only the
                ;; selected one) travels in as (:hardware-profile (:name "X" ...)).
                ((and (consp form) (eq (first form) :hardware-profile))
                  (setf hardware-profile (second form)))))
      ;; Endeavor 144 Phase 4: latch the register decision for the L0 module build.
      (let ((modes (getf hardware-profile :max-registers-per-thread))
            (sel   (getf hardware-profile :selected-registers-per-thread)))
        (setf (symbol-value (find-symbol "*L0-REGISTER-MODES*" :crisp.hoist.l0))
              (if (listp modes) modes (and modes (list modes))))
        (setf (symbol-value (find-symbol "*L0-SELECTED-REGISTERS-PER-THREAD*" :crisp.hoist.l0))
              sel))
      ;; Return as plist for easy access
      (list :aliases aliases :structs structs :records records :kernels kernels
            :hardware-profile hardware-profile))))

;; src/hoist-l0/main.lisp
(in-package :crisp.hoist.l0)

(defun %l0-register-build-flags ()
  "Endeavor 144 Phase 4: the IGC build-flag string for the compiler-selected register
   allocation, or NIL when nothing needs to be requested.

   Emits `-ze-opt-large-register-file` only when the selected allocation is ABOVE the
   profile's default (first) mode.  Returning NIL for the default case matters: large-GRF
   is not free — it halves threads-per-EU — so it must be requested only for kernels whose
   register demand actually exceeds the default allocation."
  (let ((sel   *l0-selected-registers-per-thread*)
        (modes *l0-register-modes*))
    (when (and sel modes (> sel (first modes)))
      "-ze-opt-large-register-file")))

(defun generate-module-loading (stream spv-path)
  "Generate SPIR-V module loading code.

   Endeavor 144 Phase 4: pBuildFlags now carries the compiler-selected register allocation
   (see %l0-register-build-flags) instead of being unconditionally nullptr."
  (format stream "    // Load SPIR-V module~%")
  (format stream "    const char* spv_path = \"~a\";~%" (namestring spv-path))
  (format stream "    std::vector<uint8_t> spirv_data;~%")
  (format stream "    try {~%")
  (format stream "        spirv_data = read_spirv_file(spv_path);~%")
  (format stream "    } catch (const std::exception& e) {~%")
  (format stream "        std::cerr << \"ERROR: \" << e.what() << std::endl;~%")
  (format stream "        return 1;~%")
  (format stream "    }~%~%")

  (let ((flags (%l0-register-build-flags)))
    (when flags
      (format stream "    // Endeavor 144: the kernel's register-tile demand (~a registers/thread)~%"
              *l0-selected-registers-per-thread*)
      (format stream "    // exceeds this target's default allocation (~a), so ask IGC for the larger~%"
              (first *l0-register-modes*))
      (format stream "    // register file.  Without this the JIT spills instead (measured 1.5-2x slower).~%")
      (format stream "    const char* _buildFlags = \"~a\";~%" flags))

    (format stream "    ze_module_desc_t moduleDesc = {~%")
    (format stream "        ZE_STRUCTURE_TYPE_MODULE_DESC,~%")
    (format stream "        nullptr,~%")
    (format stream "        ZE_MODULE_FORMAT_IL_SPIRV,~%")
    (format stream "        spirv_data.size(),~%")
    (format stream "        spirv_data.data(),~%")
    (format stream "        ~a,~%" (if flags "_buildFlags" "nullptr"))
    (format stream "        nullptr~%")
    (format stream "    };~%~%"))

  (format stream "    ze_module_handle_t module;~%")
  (format stream "    result = zeModuleCreate(context, device, &moduleDesc, &module, nullptr);~%")
  (format stream "    if (result != ZE_RESULT_SUCCESS) {~%")
  (format stream "        std::cerr << \"ERROR: zeModuleCreate failed: \" << result << std::endl;~%")
  (format stream "        return 1;~%")
  (format stream "    }~%")
  (format stream "    std::cout << \"Module loaded successfully\" << std::endl;~%~%"))
