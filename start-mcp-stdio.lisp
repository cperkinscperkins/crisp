(in-package :cl-user)

;; Silence all loading output to prevent JSONRPC protocol corruption
(let ((*standard-output* (make-broadcast-stream))
      (*trace-output* (make-broadcast-stream))
      (*debug-io* (make-broadcast-stream)))

  ;; Initialize Quicklisp
  (let ((ql-setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
    (when (probe-file ql-setup)
          (load ql-setup)))

  ;; Load MCP system silently
  (when (find-package :ql)
        (ql:quickload :40ants-lisp-dev-mcp :silent t)))

;; Start server on the real standard output/input
;; :port nil -> uses stdio transport
;; :in-thread nil -> blocks main thread (required for stdio)
(funcall (read-from-string "40ants-lisp-dev-mcp/core:start-server")
  :port nil
  :in-thread nil)
