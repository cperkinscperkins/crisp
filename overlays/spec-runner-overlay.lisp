;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)

;; Load the compiler overlay so the in-process test runner picks up all patches.
(let ((*package* *package*))
  (load (merge-pathnames "overlays/crisp-compiler-overlay.lisp" (uiop:getcwd))))

