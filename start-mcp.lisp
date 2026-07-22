(in-package :cl-user)

;; Ensure Quicklisp
(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package :ql)
    (load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))))

;; Ensure packages are loaded
(ql:quickload :40ants-lisp-dev-mcp :silent t)
(ql:quickload :bordeaux-threads :silent t)

(format t "~%~%------------------------------------------------------------------~%")
(format t "Starting Lisp Dev MCP on port 7890...~%")
(format t "1. Configure your MCP Client (Claude Desktop/Cursor/etc):~%")
(format t "   URL: http://localhost:7890/mcp~%")
(format t "2. Keep this window open.~%")
(format t "------------------------------------------------------------------~%~%")

;; Start the server
;; Note: The docs say (40ants-lisp-dev-mcp/core:start-server :port 7890)
(funcall (read-from-string "40ants-lisp-dev-mcp/core:start-server") :port 7890)

;; Keep main thread alive
(loop (sleep 60))
