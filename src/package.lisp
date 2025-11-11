;; src/package.lisp
(defpackage :crisp-language
  (:use) ;; <--- THIS IS THE KEY. It means "use nothing from Common Lisp."

  ;; --- 1. Import *only* the "safe" CL data symbols ---
  (:import-from :common-lisp
   #:t #:nil
   #:&optional #:&key #:&rest
   #:lambda)

  ;; --- 2. Import *only* the "safe" CL forms ---
  ;; We must "shadow" (copy) them into our package
  ;; so the user can type (if ...) instead of (cl:if ...)
  (:shadowing-import-from :common-lisp
   #:if #:when #:unless #:cond #:case
   #:let #:let*
   #:progn
   #:+ #:- #:* #:/ #:= #:/= #:< #:> #:<= #:>=
   #:equal ;; and so on...
   #:defmacro) ;; We need defmacro to build the language

  ;; --- 3. Export *all* of our Crisp primitives ---
  (:export
   ;; Our new "safe" built-ins
   #:if #:when #:let #:+ #:* ;;... all the shadowed imports

   ;; Our custom GPU functions
   #:def-kernel #:def-function #:def-grid-function
   #:def-orchestration #:def-qint #:def-microfloat-block
   #:def-type-alias #:def-struct

   ;; Our looping constructs
   #:loop-vector-stride #:loop-soa-stride
   #:thread-stride #:workgroup-stride
   #:dotimes #:dotimes*

   ;; Our memory tools
   #:vector #:matrix #:tensor
   #:storage ;; (or whatever we call it)
   #:make-scratch-vector #:make-tile
   #:load-chunk #:store-chunk #:load-tile #:store-tile
   #:~ #:set! #:length~

   ;; Our new ops
   #:*! #:identity-of #:zero #:accum #:base
   
   ;; ...and every other function we add.
   ))