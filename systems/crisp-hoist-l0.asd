(defsystem "crisp-hoist-l0"
           :description "Level Zero C++ launcher generator for Crisp kernels"
           :author "Chris Perkins"
           :version "0.1.0"
           :license "MIT"
           :depends-on (:uiop :crisp-hoist-common)
           :serial t
           :components ((:module "hoist-l0"
                                 :pathname "../src/hoist-l0"
                                 :components ((:file "package")
                                              (:file "main"))))
           :build-operation "program-op"
           :build-pathname "../bin/crisp-hoist-l0"
           :entry-point "crisp.hoist.l0:main"
           :in-order-to ((test-op (test-op "crisp-hoist-l0/tests"))))


