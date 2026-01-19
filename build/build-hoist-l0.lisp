;;;; Build script for crisp-hoist-l0.exe

(require :asdf)
(require :uiop)

(format t "; --- Building crisp-hoist-l0 ---~%")

;; Add systems directory to ASDF search path
(pushnew (merge-pathnames "systems/" (uiop:getcwd))
         asdf:*central-registry*
         :test #'equal)

;; Load and build
(format t "; Loading crisp-hoist-l0 system...~%")
(asdf:load-system "crisp-hoist-l0" :verbose nil)

(format t "; Building executable...~%")
(asdf:make "crisp-hoist-l0")

(format t "; --- Build complete: bin/crisp-hoist-l0.exe ---~%")
(uiop:quit 0)
