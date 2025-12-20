;; tests/test-struct-layout.lisp
(in-package :crisp.tests)

(define-test (crisp-compiler struct-std140-compile-time-props)
             "Verifies std140 layout ignores :c-t (compile-time) members."

             ;; Case 1: Pure Compile-Time Struct
             ;; Should have 0 runtime size.
             (multiple-value-bind (padded size) (crisp.compiler::compute-std140-layout '((a int :c-t 10) (b float :c-t 20.0)))
               (is = 0 size "Pure compile-time struct should have 0 size")
               (is = 0 (length padded) "Pure compile-time struct should have 0 runtime members"))

             ;; Case 2: Mixed (Compile-Time property, then Runtime property)
             ;; ((a :c-t) (b double))
             ;; If 'a' were runtime (int), offset would be 4, padding 4, then double at 8. Total 16.
             ;; Since 'a' is :c-t, it's ignored.
             ;; Becomes ((b double)). Offset 0. Size 8.
             ;; Standard 140 pads struct to multiple of 16. So final size 16.
             (multiple-value-bind (padded size)
                 (crisp.compiler::compute-std140-layout '((a int :c-t 10) (b double)))
               (is = 16 size "Should be 16 bytes (8 data + 8 padding, ignoring 'a')")
               ;; padded list should be ((b double) (_PAD_EA ...))
               (is = 2 (length padded))
               (is eq 'b (first (first padded)))
               (is eq 'double (second (first padded)))))
