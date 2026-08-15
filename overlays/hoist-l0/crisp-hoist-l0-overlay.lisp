(in-package :crisp.hoist.l0)


;; src/hoist-l0/main.lisp
;;
;; Endeavor 150 (fused epilogue) — raise the buffer-print cap from 100 to 512 elements.
;;
;; WHY.  A HOIST-EXPECT: BUFFER <name>: <values> expectation can only fire if the harness
;; actually prints the buffer, and this gate skipped anything over 100 elements.  The smallest
;; single MMA output tile is 128 on BOTH vendors (16x8 NVIDIA tf32, 8x16 Intel XMX), so C was
;; never printed for ANY MMA kernel — which is exactly the buffer an epilogue test needs to see.
;;
;; 512 covers a 16x16 tile (256) with headroom while still skipping genuinely large benchmark
;; buffers.  Note the CUDA hoist has no such gate at all (it prints every buffer), so this only
;; brings L0 into line with what CUDA already did.
;;
;; Everything else in this function is byte-identical to the original.

(defun generate-cpp-main (stream kernel-name spv-path declared-sig aliases records &optional dispatch-info)
  "Generate C++ main.  Endeavor 134: under --mma-test, appends a host-reference C=A·B check.
   Endeavor 150: buffer-print cap raised 100 -> 512 so MMA-sized output tiles are printable
   and can be checked with a HOIST-EXPECT: BUFFER expectation."
  (format stream "int main() {~%")
  (format stream "    ze_result_t result;~%")
  (format stream "    std::cout << \"Level Zero Launcher for kernel: ~a\" << std::endl;~%~%" kernel-name)
  (generate-l0-init stream)
  (when spv-path (generate-module-loading stream spv-path))
  (setf *mma-input-counter* 0)          ; reset role assignment for this kernel
  (let ((allocations (generate-kernel-launch stream kernel-name declared-sig aliases records dispatch-info)))
    (format stream "    // Verify Output (skipped if large)~%")
    (dolist (alloc allocations)
      (let ((name (getf alloc :name)) (ptr (getf alloc :ptr)) (size-v (getf alloc :size-var)))
        (format stream "    if (~a <= 512) {~%" size-v)
        (format stream "        std::cout << \"BUFFER ~a: \";~%" name)
        (format stream "        for (size_t i = 0; i < ~a; i++) {~%" size-v)
        (format stream "            std::cout << ~a[i] << (i == ~a - 1 ? \"\" : \" \");~%" ptr size-v)
        (format stream "        }~%")
        (format stream "        std::cout << std::endl;~%")
        (format stream "    }~%")))
    (when *mma-test-dims*
      (%l0-emit-mma-reference stream allocations))
    (format stream "    std::cout << \"Success!\" << std::endl;~%")
    (format stream "    return 0;~%")
    (format stream "}~%")))
