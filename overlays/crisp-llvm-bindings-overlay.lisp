;;; HOT-PATCH OVERLAY for CRISP.LLVM-BINDINGS
;;; ---------------------------------------------------------------------------
;;; INSTRUCTIONS:
;;; 1. Append new/fixed function definitions to the end of this file.
;;; 2. Add a comment referencing the original file (e.g. ;;; FROM: src/environment.lisp)
;;; 3. Do not modify the original file in src/ until cleanup time.

(in-package :crisp.llvm-bindings)

;;; ===================================================================
;;; In-process optimizer (2026-07-06) — new-pass-manager + target-machine
;;; C API, so the compile pipeline can run `default<O3>` via the already-
;;; loaded libLLVM instead of shelling out to an `opt` binary (which isn't
;;; present on the Windows dev box).  Probed present in the shipped
;;; LLVM-C.dll (Windows) incl. a working NVPTX TargetMachine.
;;; FROM: src/llvm-bindings.lisp
;;; ===================================================================

(defcfun ("LLVMContextCreate" llvm-context-create) :pointer
  "Create a fresh LLVM context (for parsing a standalone .ll to optimize).")

(defcfun ("LLVMContextDispose" llvm-context-dispose) :void
  (context :pointer))

(defcfun ("LLVMCreatePassBuilderOptions" llvm-create-pass-builder-options) :pointer
  "Options object for LLVMRunPasses (new pass manager).")

(defcfun ("LLVMDisposePassBuilderOptions" llvm-dispose-pass-builder-options) :void
  (opts :pointer))

(defcfun ("LLVMRunPasses" llvm-run-passes) :pointer   ; LLVMErrorRef (NULL = success)
  "Run PASSES (e.g. \"default<O3>\") on MODULE using TM (may be NULL) and OPTS.
   Returns NULL on success, else an LLVMErrorRef."
  (module :pointer) (passes :string) (tm :pointer) (opts :pointer))

(defcfun ("LLVMGetErrorMessage" llvm-get-error-message) :string
  "Consume ERR and return its human-readable message."
  (err :pointer))

(defcfun ("LLVMGetTarget" llvm-get-target) :string
  "The target triple recorded in MODULE."
  (module :pointer))

(defcfun ("LLVMGetTargetFromTriple" llvm-get-target-from-triple) :int  ; 0 = success
  "Resolve TRIPLE to a registered LLVMTargetRef (written to OUT-TARGET); on
   failure writes an error string to OUT-ERR.  Returns 0 on success."
  (triple :string) (out-target :pointer) (out-err :pointer))

(defcfun ("LLVMCreateTargetMachine" llvm-create-target-machine) :pointer
  "Build a TargetMachine (for TTI/cost-model during opt)."
  (target :pointer) (triple :string) (cpu :string) (features :string)
  (opt-level :int) (reloc :int) (code-model :int))

(defcfun ("LLVMDisposeTargetMachine" llvm-dispose-target-machine) :void
  (tm :pointer))

(defcfun ("LLVMInitializeNVPTXTargetInfo" llvm-initialize-nvptx-target-info) :void)
(defcfun ("LLVMInitializeNVPTXTarget" llvm-initialize-nvptx-target) :void)
(defcfun ("LLVMInitializeNVPTXTargetMC" llvm-initialize-nvptx-target-mc) :void)

