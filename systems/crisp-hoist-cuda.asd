(defsystem "crisp-hoist-cuda"
           :description "CUDA C++ launcher generator for Crisp kernels (Driver API)"
           :author "Chris Perkins"
           :version "0.1.0"
           :license "MIT"
           :depends-on (:uiop :crisp-hoist-common)
           :serial t
           :components ((:module "hoist-cuda"
                                 :pathname "../src/hoist-cuda"
                                 :components ((:file "package")
                                              (:file "main"))))
           :build-operation "program-op"
           :build-pathname "../bin/crisp-hoist-cuda"
           :entry-point "crisp.hoist.cuda:main")
