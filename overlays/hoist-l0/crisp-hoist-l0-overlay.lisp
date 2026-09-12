(in-package :crisp.hoist.l0)


;; src/hoist-l0/main.lisp
(defun %l0-emit-mma-reference (stream allocations)
  "Emit a stride-agnostic host reference C = A·B, checked on a STRIDED 64x64 sample of C.

   2026-09-12: this used to check only the TOP-LEFT 64x64 corner of C.  That is the same cost as
   a strided sample and blind to every tile it does not reach -- a kernel that wrote only its
   first tile printed MMA_CORRECT.  It mattered more than it looked: on BMG six of the twelve
   section-1 ladder kernels (chap1..chap3, tf32 and bf16) are measured through THIS harness,
   because the reviewed fixture cannot bind SLM tensor arguments.  The strided form mirrors
   benchmarks/matmul/crisp/bench_harness_l0.cpp, which made the same change for the same reason.

   Cost is unchanged in kind: ~64x64 samples x K, well under a second at N=16384.  C is read back
   over its whole extent, so the sample can land anywhere; the operands are still RECOMPUTED from
   the fill formula rather than read (see endeavour 155: a host dereference of USM aborts on the
   BMG/WSL driver).  The final line is still exactly MMA_CORRECT / MMA_WRONG, which is what
   HOIST-EXPECT and matmul.py match; the sample count is printed on the line before it."
  (destructuring-bind (m n k) *mma-test-dims*
    (let ((a (find :a allocations :key (lambda (x) (getf x :mma-role))))
          (b (find :b allocations :key (lambda (x) (getf x :mma-role))))
          (c (find :c allocations :key (lambda (x) (getf x :mma-role)))))
      ;; No log4cl here: crisp-hoist-l0 is a standalone app that does not load it.
      (when (and a b c)
        (let ((ab (getf a :base)) (bb (getf b :base)) (cb (getf c :base)))
          (format stream "~%    // Endeavor 134: MMA host reference C = A.B (stride-agnostic), STRIDED 64x64 sample~%")
          (format stream "    { int mma_ok = 1; int mma_bad = 0; uint64_t mma_checked = 0;~%")
          (format stream "      const uint64_t mma_M = ~dULL, mma_N = ~dULL;~%" m n)
          (format stream "      uint64_t mma_si = (mma_M + 63) / 64; if (mma_si == 0) mma_si = 1;~%")
          (format stream "      uint64_t mma_sj = (mma_N + 63) / 64; if (mma_sj == 0) mma_sj = 1;~%")
          ;; The whole extent of C under ITS strides, so any sampled (i, j) is in the buffer
          ;; whether C is row- or column-major.
          (format stream "      uint64_t mma_c_extent = (mma_M - 1) * ~a_str0 + (mma_N - 1) * ~a_str1 + 1;~%" cb cb)
          (format stream "      float* host_c_buf = (float*)malloc(mma_c_extent * sizeof(float));~%")
          (format stream "      if (!host_c_buf) { mma_ok = 0; std::cout << \"  host readback allocation failed\" << std::endl; } else {~%")
          (format stream "      zeCommandListCreate(context, device, &cmdListDesc, &cmdList);~%")
          (format stream "      zeCommandListAppendMemoryCopy(cmdList, host_c_buf, ~a_ptr, mma_c_extent * sizeof(float), nullptr, 0, nullptr);~%" cb)
          (format stream "      zeCommandListClose(cmdList);~%")
          (format stream "      zeCommandQueueExecuteCommandLists(cmdQueue, 1, &cmdList, nullptr);~%")
          (format stream "      zeCommandQueueSynchronize(cmdQueue, UINT64_MAX);~%")
          (format stream "      zeCommandListDestroy(cmdList);~%")
          (format stream "      for (uint64_t i = 0; i < mma_M; i += mma_si) for (uint64_t j = 0; j < mma_N; j += mma_sj) {~%")
          (format stream "        ++mma_checked;~%")
          (format stream "        float acc = 0.0f;~%")
          (format stream "        for (uint64_t kk = 0; kk < ~dULL; kk++)~%" k)
          (format stream "            acc += (float)((i*~a_str0 + kk*~a_str1) % ~dULL) * (float)((kk*~a_str0 + j*~a_str1) % ~dULL);~%"
                  ab ab (%l0-mma-fill-modulus :a) bb bb (%l0-mma-fill-modulus :b))
          (when (/= *mma-scale* 1)
            (format stream "        acc = acc * ~d.0f;   // --mma-scale (MMA fired ~:*~d× per fragment)~%" *mma-scale*))
          (format stream "        float got = host_c_buf[i*~a_str0 + j*~a_str1];~%" cb cb)
          (format stream "        float d = got - acc; if (d < 0) d = -d;~%")
          (format stream "        if (d > 1e-2f * (acc < 0 ? -acc : acc) + 1e-3f) { mma_ok = 0;~%")
          (format stream "            if (mma_bad < 4) { std::cout << \"  C[\" << i << \"][\" << j << \"]=\" << got << \" ref \" << acc << std::endl; mma_bad++; } }~%")
          (format stream "      }~%")
          (format stream "      free(host_c_buf); }~%")
          (format stream "      std::cout << \"  mma reference: \" << mma_checked << \" strided samples\" << std::endl;~%")
          (format stream "      std::cout << (mma_ok ? \"MMA_CORRECT\" : \"MMA_WRONG\") << std::endl; }~%"))))))
