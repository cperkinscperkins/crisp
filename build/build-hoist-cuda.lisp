;;;; Build script for crisp-hoist-cuda.exe

(require :asdf)
(require :uiop)

(format t "; --- Building crisp-hoist-cuda ---~%")

;; Add systems directory to ASDF search path
(pushnew (merge-pathnames "systems/" (uiop:getcwd))
         asdf:*central-registry*
         :test #'equal)

;; delete old executable
(uiop::ensure-directories-exist "bin/")
(let ((exe (merge-pathnames "bin/crisp-hoist-cuda.exe" *default-pathname-defaults*)))
  (when (probe-file exe)
        (format t "~&; Deleting old executable: ~a~%" exe)
        (delete-file exe)))

;; Load and build
(format t "; Loading crisp-hoist-cuda system...~%")
(asdf:load-system "crisp-hoist-cuda" :verbose nil)

;; Load overlay
(let ((overlay "overlays/hoist-cuda/crisp-hoist-cuda-overlay.lisp"))
  (if (probe-file overlay)
      (progn
       (format t "; Loading overlay: ~a~%" overlay)
       (load overlay))
      (format t "; No overlay found at ~a~%" overlay)))

(format t "; Building executable...~%")
(asdf:make "crisp-hoist-cuda")

(format t "; --- Build complete: bin/crisp-hoist-cuda.exe ---~%")
(uiop:quit 0)
