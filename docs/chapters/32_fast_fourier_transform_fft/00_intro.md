# Fast Fourier Transform (FFT)


The routines and orchestration below implement the Fast Fourier Transform using the Cooley-Tukey algorithm. 
It first optionally rearranges the input data using a bit-reversal permutation. 
Then, it precomputes the necessary complex constants called twiddle factors. 
The core of the algorithm is a loop that iterates through several stages. 
In each stage, it launches the fft-pass kernel, which performs parallel "butterfly" operations 
across the dataset, progressively transforming the data from the time domain to the frequency domain. 
This process uses temporary "ping-pong" buffers to store intermediate results between stages. 
Finally, a concluding step ensures the fully transformed data resides in the designated output vector.

Performance Note: The implementation below is a direct global-memory implementation. 
For maximum performance, real-world FFTs often use tiling with local memory (similar to matmul) 
to improve data reuse and reduce global memory traffic.
Additionally, some of the core operations in FFT are just dot products on both the real and imaginary part of a complex number. This can be accelerated by using the widening
accumulator hardware types like quantized integers and microfloat blocks. 

```
;;
;;  calculate-twiddle-factor
;;
;; templated with a floating point type
(with-template-type (T A)
  (declare (is-type T #'is-floating-point?) (is-value A #'is-alignment?))

  ;; -- calculate-twiddle-factor --
  (def-function calculate-twiddle-factor (k N)
    ;; $W_N^k = \cos(2\pi k/N) - i\sin(2\pi k/N)$
    (declare #(ulong ulong => (complex-type T)))
    (let ((angle:T (/ (* -2.0 PI (as T k)) (as T N))))
      (make-complex (cos angle) (sin angle))))


;;
;; precompute-twiddles
;;
  ;; -- precompute-twiddles --
  (def-grid-function precompute-twiddles (N &out twiddle-vec)
    (declare #(ulong &out (vector (complex-type T) :address-space :global :access :writeable :align A) => nil))

    ;; Each thread calculates twiddle factors using grid stride
    (loop-vector-stride twiddle-vec (k) ; Loop from k = 0 to N-1 (or length of twiddle-vec)
      (when (< k N) ; Ensure we only calculate N twiddles
        ;; Calculate the k-th twiddle factor
        (let ((twiddle (calculate-twiddle-factor k N)))
          ;; Store it in the output vector
          (set! (~ twiddle-vec k) twiddle))))))

;;
;; fft-butterfly
;;
;; Templated on complex type CT (which implies float type T)
(with-template-type (CT)
  (declare (type-is CT #'is-complex?))

  ;; -- fft-butterfly --
  (def-function fft-butterfly (a b w)
    ;; $A' = A + BW, B' = A - BW$ 
    (declare #(CT CT CT => CT CT)) ; Returns two complex values
    (let ((bw (* b w)))
      (return (+ a bw) (- a bw)))))


(with-template-type (T A)
  (declare (value-is A #'is-alignment?)) ;; T can be any type here

;;
;; reverse-bits
;;
  ;; Helper function to reverse bits (thread-level)

  ;; -- reverse-bits --
  (def-function reverse-bits (index num-bits)
    (declare #(ulong ulong => ulong))
    (let ((reversed-index 0))
      (dotimes (i num-bits)
        ;; Add the least significant bit of 'index' to the most significant
        ;; available position in 'reversed-index'
        (set! reversed-index (logior (ash reversed-index 1)
                                      (bit-and index 1)))
        ;; Shift 'index' right to process the next bit
        (set! index (ash index -1))))
      (return reversed-index)))
;;
;; bit-reverse-copy
;;
  ;; The main grid function

  ;; -- bit-reverse-copy --
  (def-grid-function bit-reverse-copy (input-vec N &out output-vec)
    (declare #((vector T :address-space :global :access :readable :align A)
               ulong
               &out (vector T :address-space :global :access :writeable :align A) => nil))

    (let ((num-bits (log2 N))) ; Calculate number of bits needed for N indices
      ;; Use grid stride for parallelism - each thread handles multiple indices
      (loop-vector-stride input-vec (i)
        ;; 1. Calculate the destination index by reversing the bits of 'i'
        (let ((dest-index (reverse-bits i num-bits)))
          ;; 2. Read the value from the source index 'i' (coalesced read)
          (let ((val (~ input-vec i)))
            ;; 3. Write the value to the bit-reversed destination index (uncoalesced write)
            (set! (~ output-vec dest-index) val)))))))

;;
;; fft-pass
;;
(with-template-type (T A CT) ; T=float type, A=alignment, CT=complex type
  (declare (type-is T #'is-floating-point?)
           (value-is A #'is-alignment?)
           (type-is CT #'is-complex?)) ; Assuming is-complex? exists

  ;; The main grid function for one FFT pass

  ;; -- fft-pass --
  (def-grid-function fft-pass (input-vec twiddle-vec stage pass-stride N &out output-vec)
    (declare #((vector CT :address-space :global :access :readable :align A) ; Input data
               (vector CT :address-space :global :access :readable :align A) ; Twiddle factors (size N/2)
               ulong ; Current stage (0 to log2N-1)
               ulong ; Stride for this pass (2^stage)
               ulong ; Total FFT size (power of 2)
               &out (vector CT :address-space :global :access :writeable :align A) => nil)) ; Output data

    ;; Use grid stride - each thread calculates one butterfly output pair
    (loop-vector-stride output-vec (i)
      (when (< i (/ N 2)) ; Each thread handles one pair, so loop up to N/2

        ;; --- 1. Calculate Indices ---
        ;; This is the tricky part: determine which two elements (idx1, idx2)
        ;; and which twiddle factor (k) this thread 'i' is responsible for.
        ;; This specific indexing pattern is for the decimation-in-time algorithm.
        (let ((group-len pass-stride)          ; Length of the sub-DFT groups
              (half-group-len (/ group-len 2))
              (group-num (floor i half-group-len))
              (idx-in-group (mod i half-group-len))
               ;; Indices for the butterfly input elements
              (idx1 (+ (* group-num group-len) idx-in-group))
              (idx2 (+ idx1 half-group-len))
               ;; Index for the twiddle factor W_N^k
               ;; (Note: Needs adjustment based on N and pass_stride)
              (k (* idx-in-group (/ N group-len))))

          ;; --- 2. Perform Butterfly ---
          ;; Check bounds (important if N is not perfectly divisible)
          (when (and (< idx1 N) (< idx2 N))
            ;; Load inputs
            (let ((a (~ input-vec idx1))
                  (b (~ input-vec idx2))
                  ;; Load twiddle factor (using 'k' calculated above)
                  (w (~ twiddle-vec k)))

              ;; Perform the butterfly operation
              (multiple-value-bind (a-prime b-prime) (fft-butterfly a b w)

                ;; --- 3. Store Results ---
                ;; Write the two results to the output vector
                (set! (~ output-vec idx1) a-prime)
                (set! (~ output-vec idx2) b-prime)))))))))

```

Now using soa-vector for better performance

> CODE BELOW NOT ENTIRELY COMPLETE
> also def-orch definition needs more work

```
;; -- load-complex-soa-tile --
(defmacro load-complex-soa-tile (soa-vec tile-y tile-x local-reals local-imags)
  ;; Macro expands into the efficient load logic:
  `(let ((tile-dim (num-cols ,local-reals)) ; Assume square tile
         (local-id-x (get-local-id 0))
         (local-id-y (get-local-id 1)))

     ;; Calculate Global Source Coordinates (Coalesced for Components)
     (let ((source-x (+ (* ,tile-x tile-dim) local-id-x))
           (source-y (+ (* ,tile-y tile-dim) local-id-y)))

       ;; Read Components and Write to Separate Local Tiles
       (when (and (< source-y (length~ ,soa-vec)) (< source-x tile-dim)) ; Adjust bounds check
         ;; Coalesced read from real component array
         (set! (~ ,local-reals local-id- local-id-x) (real~ ,soa-vec source-y))
         ;; Coalesced read from imag component array
         (set! (~ ,local-imags local-id-y local-id-x) (imag~ ,soa-vec source-y))))))

;;
;; fft-pass-soa-tiled -- This requires a 2D enqueue
;;
(def-const TILE_DIM +warp-size+) ; 32
(with-template-type (T A CT) ; T=float type, A=alignment, CT=complex type
  (declare (type-is T #'is-floating-point?)
           (value-is A #'is-alignment?)
           (type-is CT #'is-complex?))

  ;; -- fft-pass-soa-tiled --
  (def-grid-function fft-pass-soa-tiled (input-soa-vec twiddle-vec stage pass-stride N &out output-vec)
      ;; same signature as fft-pass ?
      (declare #((soa-vector CT :global :readable A) ; Input data
                (vector CT :address-space :global :access :readable :align A) ; Twiddle factors (size N/2)
                ulong ; Current stage (0 to log2N-1)
                ulong ; Stride for this pass (2^stage)
                ulong ; Total FFT size (power of 2)
                &out (soa-vector CT :address-space :global :access :writeable :align A) => nil) ; Output data
                (local-size :dims 2 :msg "fft-pass-soa-tiled requires a 2D enqueue"))
      
      ;; Define TWO local memory tiles
      (def-local-mem local-reals (matrix T TILE_DIM TILE_DIM))
      (def-local-mem local-imags (matrix T TILE_DIM TILE_DIM))

      ;; Load the tile for this workgroup
      (load-complex-soa-tile input-soa-vec tile-y tile-x local-reals local-imags)
      (local-barrier) ; Ensure loading is done

      (let ((local-id-x (get-local-id 0)) (local-id-y (get-local-id 1))
            (group-id-x (get-group-id 0)) (group-id-y (get-group-id 1)))

        ;; LOOP OVER WORK BLOCKS (If workgroup handles multiple butterflies)
        ;; This part depends on how work is assigned (e.g., each thread doing multiple butterflies)
        ;; Let's simplify and assume one butterfly per thread for now, matching non-tiled.

        ;; LOAD TILE INTO SoA FORMAT
        ;; Use a hypothetical SoA-aware load macro. This handles coalescing.
        (load-tile-soa input-vec local-reals local-imags group-idy group-idx)
        (local-barrier)

        ;; COMPUTE BUTTERFLIES IN LOCAL MEMORY 
        ;; This part needs careful indexing based on the FFT stage/stride
        ;; Let's assume 'idx1', 'idx2', 'k' are calculated as before
        (when (< (get-global-id) (/ N 2))
            (let (;; Calculate indices within the local tile
                  (local-idx1 ...) (local-idy1 ...)
                  (local-idx2 ...) (local-idy2 ...)
                  (k ...)) ; Twiddle index
                  
              ;; Load components from SoA local tile
              (let ((a-re (~ local-reals local-idy1 local-idx1))
                    (a-im (~ local-imags local-idy1 local-idx1))
                    (b-re (~ local-reals local-idy2 local-idx2))
                    (b-im (~ local-imags local-idy2 local-idx2))
                    (w (~ twiddle-vec k))) ; Assume twiddles are AoS complex

                ;; Perform SoA butterfly
                (multiple-value-bind (ap-re ap-im bp-re bp-im)
                    (fft-butterfly-soa a-re a-im b-re b-im (real~ w) (imag~ w))

                  ;; WRITE RESULTS BACK TO SoA LOCAL TILE
                  ;; Need barriers between stages if results overwrite inputs needed later
                  (set! (~ local-reals local-idy1 local-idx1) ap-re)
                  (set! (~ local-imags local-idy1 local-idx1) ap-im)
                  (set! (~ local-reals local-idy2 local-idx2) bp-re)
                  (set! (~ local-imags local-idy2 local-idx2) bp-im)))))
        (local-barrier)

        ;; STORE TILE FROM SoA FORMAT 
        ;; Use a hypothetical SoA-aware store macro. This handles coalescing.
        (store-complex-soa-tile local-reals local-imags output-vec group-idy group-idx))))

;;
;; fft-butterfly-soa
;;
;; Takes real/imag parts of a, b, w. Returns real/imag of a' and b'.
(with-template-type (T)
  (declare (type-is T #'is-floating-point?))

  ;; -- fft-butterfly-soa --
  (def-function fft-butterfly-soa (a-re a-im b-re b-im w-re w-im)
    (declare #(T T T T T T => T T T T)) ; RealA', ImagA', RealB', ImagB'
    ;; Calculate BW = (b_re*w_re - b_im*w_im) + (b_re*w_im + b_im*w_re)i
    (let ((bw-re (- (* b-re w-re) (* b-im w-im)))
          (bw-im (+ (* b-re w-im) (* b-im w-re))))
      ;; Return A' = A + BW and B' = A - BW
      (return (+ a-re bw-re) (+ a-im bw-im) ; RealA', ImagA'
              (- a-re bw-re) (- a-im bw-im))))) ; RealB', ImagB'

```


And a possible orchestration
```
(with-template-type (T A)

  ;; -- fft -- 
  (def-orchestration fft 

    ;; Define temp buffers (A for bit-reversed, B for ping-pong)
    (make-temp-vector buffer-A ...)
    (make-temp-vector buffer-B ...)
    (make-temp-vector twiddles ...) ; Need twiddle factor table

    (launch-sequential
      ;; Optional: Bit-reverse input into buffer-A
      ((gen-bit-reverse-copy T A) input-vec buffer-A (length~ input-vec))

      ;; Precompute twiddles (could be another kernel or host-side)
      ((gen-precompute-twiddles T A) twiddles (length~ input-vec)))

    ;; Host loop over FFT stages
    (loop-host ((stage 0 (+ stage 1)) :times (log2 (length~ input-vec)))
      (let ((pass-stride (expt 2 stage))
            ;; Determine input/output for ping-pong
            (current-input (if (even? stage) buffer-A buffer-B))
            (current-output (if (even? stage) buffer-B buffer-A)))
        (launch-sequential
          ((gen-fft-pass T A) current-input twiddles stage pass-stride current-output))))

    ;; Final copy to ensure output is in the right buffer
    (copy-final (if (even? (log2 (length~ input-vec))) buffer-A buffer-B) output-vec)))
```

