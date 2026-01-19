(defsystem "crisp-hoist-common"
           :description "Common infrastructure for Crisp hoisting tools"
           :author "Chris Perkins"
           :version "0.1.0"
           :license "MIT"
           :depends-on (:uiop)
           :serial t
           :components ((:module "hoist"
                                 :pathname "../src/hoist"
                                 :components ((:file "package")
                                              (:file "common")
                                              (:file "codegen-base"))))
           :in-order-to ((test-op (test-op "crisp-hoist-common/tests"))))

;; Load overlay after main system
(eval-when (:load-toplevel :execute)
  (let ((overlay-path (merge-pathnames "overlays/hoist-common/crisp-hoist-common-overlay.lisp"
                                       (asdf:system-source-directory "crisp-hoist-common"))))
    (when (probe-file overlay-path)
          (load overlay-path))))
