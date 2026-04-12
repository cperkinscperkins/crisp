;; tests/test-struct-layout.lisp
(in-package :crisp.tests)

(define-test (crisp-compiler struct-native-compile-time-props)
             "Verifies native scalar layout ignores :c-t (compile-time) members."

             ;; Case 1: Pure Compile-Time Struct
             ;; Should have 0 runtime size.
             (multiple-value-bind (padded size) (crisp.compiler::compute-native-layout '((a int :c-t 10) (b float :c-t 20.0)))
               (is = 0 size "Pure compile-time struct should have 0 size")
               (is = 0 (length padded) "Pure compile-time struct should have 0 runtime members"))

             ;; Case 2: Mixed (Compile-Time property, then Runtime property)
             ;; ((a int :c-t) (b double))
             ;; 'a' is :c-t, so ignored. Becomes ((b double)).
             ;; double at offset 0, size 8. max_align=8, 8%8=0 -> no trailing pad.
             ;; Native scalar: size = 8 (no 16-byte pad).
             (multiple-value-bind (padded size)
                 (crisp.compiler::compute-native-layout '((a int :c-t 10) (b double)))
               (is = 8 size "Should be 8 bytes (just the double, no trailing pad in native scalar)")
               ;; padded list should be just ((b double)) - no trailing pad needed
               (is = 1 (length padded))
               (is eq 'b (first (first padded)))
               (is eq 'double (second (first padded)))))
