;;;; Build script for crisp-hoist-l0.exe

(require :asdf)
(require :uiop)

(format t "; --- Building crisp-hoist-l0 ---~%")

;; Add systems directory to ASDF search path
(pushnew (merge-pathnames "systems/" (uiop:getcwd))
         asdf:*central-registry*
         :test #'equal)

;; delete old executable
(uiop::ensure-directories-exist "bin/")
(let ((exe (merge-pathnames (if (uiop:os-windows-p) "bin/crisp-hoist-l0.exe" "bin/crisp-hoist-l0") *default-pathname-defaults*)))
  (when (probe-file exe)
        (format t "~&; Deleting old executable: ~a~%" exe)
        (delete-file exe)))

;; Load and build
(format t "; Loading crisp-hoist-l0 system...~%")
(asdf:load-system "crisp-hoist-l0" :verbose nil)

;; Load overlay
(let ((overlay "overlays/hoist-l0/crisp-hoist-l0-overlay.lisp"))
  (if (probe-file overlay)
      (progn
       (format t "; Loading overlay: ~a~%" overlay)
       (load overlay))
      (format t "; No overlay found at ~a~%" overlay)))

(format t "; Building executable...~%")
(asdf:make "crisp-hoist-l0")

(format t "; --- Build complete: bin/crisp-hoist-l0.exe ---~%")
(uiop:quit 0)
