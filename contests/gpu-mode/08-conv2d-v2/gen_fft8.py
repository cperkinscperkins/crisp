#!/usr/bin/env python3
"""Generate conv2d_fft8.crisp: the radix-8 forward / inverse tile FFTs of the conv2d_v2 FFT lane.

Each 64-point FFT is 8 x 8 (n = 8 n1 + n2, k = k1 + 8 k2): step A = an 8-point DFT over n1 for each n2,
times the twiddle W64^(n2 k1); step B = an 8-point DFT over n2 for each k1.  In place, so the result lands
digit-swapped: frequency f sits at position perm8(f) = 8 (f mod 8) + f / 8.  The inverse runs B^-1 then
A^-1 and lands natural.  The eight load / DFT8 / twiddle / store steps differ only in their addresses, so
they are generated here rather than typed; edit this file and re-run it.
"""
from pathlib import Path

HERE = Path(__file__).resolve().parent
RS = 73          # shared row stride: element (r, c) at r * 73 + c + c / 8 (see the header comment)


def step(indent, base, stride, inverse, twiddle_group=None, guard=None):
    """One radix-8 step: load 8 complex values at base + stride * j, DFT8 (inverse: conjugate DFT8),
    optionally multiply output j by W64^(+-group * j), store them back in place."""
    p = " " * indent
    fn = "idft8" if inverse else "dft8"
    loads = " ".join(f"(~ re (+ pb {j * stride}u)) (~ im (+ pb {j * stride}u))" for j in range(8))
    names = " ".join(f"b{j}r b{j}i" for j in range(8))
    lines = [f"(let ((pb {base}))",
             f"  (let (({names}",
             f"         ({fn} {loads})))"]
    body = []
    for j in range(8):
        tgt = f"(+ pb {j * stride}u)"
        if twiddle_group is None or j == 0:
            body.append(f"(set! (~ re {tgt}) b{j}r) (set! (~ im {tgt}) b{j}i)")
        else:
            m = f"(* {twiddle_group} {j}u)"
            # forward: (b)(wr + i wi);  inverse: (b)(wr - i wi)
            if inverse:
                body.append(f"(let ((wr (~ twr {m})) (wi (~ twi {m})))\n"
                            f"{p}      (set! (~ re {tgt}) (+ (* b{j}r wr) (* b{j}i wi)))\n"
                            f"{p}      (set! (~ im {tgt}) (- (* b{j}i wr) (* b{j}r wi))))")
            else:
                body.append(f"(let ((wr (~ twr {m})) (wi (~ twi {m})))\n"
                            f"{p}      (set! (~ re {tgt}) (- (* b{j}r wr) (* b{j}i wi)))\n"
                            f"{p}      (set! (~ im {tgt}) (+ (* b{j}i wr) (* b{j}r wi))))")
    lines += ["    " + b for b in body]
    lines[-1] += "))"
    out = "\n".join(p + l for l in lines)
    if guard:
        out = f"{p}(when {guard}\n" + "\n".join("  " + l for l in out.split("\n")) + ")"
    return out


DFT8 = r'''
;; An 8-point DFT of (a0 .. a7), forward sign (W8 = e^(-2 pi i / 8)), as two 4-point DFTs (even / odd).
(def-function dft8 (a0r a0i a1r a1i a2r a2i a3r a3i a4r a4i a5r a5i a6r a6i a7r a7i)
  (declare #'(float float float float float float float float float float float float float float float float
              => float float float float float float float float float float float float float float float float))
  (let ((t0r (+ a0r a4r)) (t0i (+ a0i a4i)) (t1r (- a0r a4r)) (t1i (- a0i a4i))
        (t2r (+ a2r a6r)) (t2i (+ a2i a6i)) (dr  (- a2r a6r)) (di  (- a2i a6i))
        (e0r (+ t0r t2r)) (e0i (+ t0i t2i)) (e2r (- t0r t2r)) (e2i (- t0i t2i))
        (e1r (+ t1r di))  (e1i (- t1i dr))  (e3r (- t1r di))  (e3i (+ t1i dr))       ; -i d = (di, -dr)
        (s0r (+ a1r a5r)) (s0i (+ a1i a5i)) (s1r (- a1r a5r)) (s1i (- a1i a5i))
        (s2r (+ a3r a7r)) (s2i (+ a3i a7i)) (fr  (- a3r a7r)) (fi  (- a3i a7i))
        (o0r (+ s0r s2r)) (o0i (+ s0i s2i)) (o2r (- s0r s2r)) (o2i (- s0i s2i))
        (o1r (+ s1r fi))  (o1i (- s1i fr))  (o3r (- s1r fi))  (o3i (+ s1i fr))
        (q1r (* (+ o1r o1i) 0.70710678118654752)) (q1i (* (- o1i o1r) 0.70710678118654752))  ; W8^1
        (q2r o2i) (q2i (- o2r))                                                            ; W8^2 = -i
        (q3r (* (- o3i o3r) 0.70710678118654752)) (q3i (* (- (+ o3r o3i)) 0.70710678118654752)))  ; W8^3
    (return (+ e0r o0r) (+ e0i o0i) (+ e1r q1r) (+ e1i q1i) (+ e2r q2r) (+ e2i q2i) (+ e3r q3r) (+ e3i q3i)
            (- e0r o0r) (- e0i o0i) (- e1r q1r) (- e1i q1i) (- e2r q2r) (- e2i q2i) (- e3r q3r) (- e3i q3i))))

;; The same with the inverse sign (W8 = e^(+2 pi i / 8)), unscaled.
(def-function idft8 (a0r a0i a1r a1i a2r a2i a3r a3i a4r a4i a5r a5i a6r a6i a7r a7i)
  (declare #'(float float float float float float float float float float float float float float float float
              => float float float float float float float float float float float float float float float float))
  (let ((t0r (+ a0r a4r)) (t0i (+ a0i a4i)) (t1r (- a0r a4r)) (t1i (- a0i a4i))
        (t2r (+ a2r a6r)) (t2i (+ a2i a6i)) (dr  (- a2r a6r)) (di  (- a2i a6i))
        (e0r (+ t0r t2r)) (e0i (+ t0i t2i)) (e2r (- t0r t2r)) (e2i (- t0i t2i))
        (e1r (- t1r di))  (e1i (+ t1i dr))  (e3r (+ t1r di))  (e3i (- t1i dr))       ; +i d = (-di, dr)
        (s0r (+ a1r a5r)) (s0i (+ a1i a5i)) (s1r (- a1r a5r)) (s1i (- a1i a5i))
        (s2r (+ a3r a7r)) (s2i (+ a3i a7i)) (fr  (- a3r a7r)) (fi  (- a3i a7i))
        (o0r (+ s0r s2r)) (o0i (+ s0i s2i)) (o2r (- s0r s2r)) (o2i (- s0i s2i))
        (o1r (- s1r fi))  (o1i (+ s1i fr))  (o3r (+ s1r fi))  (o3i (- s1i fr))
        (q1r (* (- o1r o1i) 0.70710678118654752)) (q1i (* (+ o1r o1i) 0.70710678118654752))  ; W8^-1
        (q2r (- o2i)) (q2i o2r)                                                            ; W8^-2 = i
        (q3r (* (- (+ o3r o3i)) 0.70710678118654752)) (q3i (* (- o3r o3i) 0.70710678118654752)))  ; W8^-3
    (return (+ e0r o0r) (+ e0i o0i) (+ e1r q1r) (+ e1i q1i) (+ e2r q2r) (+ e2i q2i) (+ e3r q3r) (+ e3i q3i)
            (- e0r o0r) (- e0i o0i) (- e1r q1r) (- e1i q1i) (- e2r q2r) (- e2i q2i) (- e3r q3r) (- e3i q3i))))

;; Shared offset of column position cp (0 .. 63) within a row: one pad word per 8 columns.
(def-function coff (cp)
  (declare #'(uint => uint))
  (+ cp (shift-right cp 3u)))

;; Where frequency f (0 .. 63) of a radix-8 transform sits: its two octal digits swapped.
(def-function perm8 (f)
  (declare #'(uint => uint))
  (+ (* (logand f 7u) 8u) (shift-right f 3u)))
'''

HEADER = f''';; conv2d_v2 FFT lane, radix-8 tile transforms (GENERATED by gen_fft8.py -- edit that, then re-run it).
;;
;; Same contract as conv2d_fft.crisp's fft_fwd / fft_inv (layouts, dims, scrambled bin order shared by X, W
;; and Y), but each 64-point FFT is two radix-8 steps done in registers instead of six radix-2 stages in
;; shared memory: 4 barriers per tile instead of 12, a third of the shared traffic.  The bin order differs
;; from conv2d_fft.crisp's (digit-swapped instead of bit-reversed), so fft8_fwd pairs only with fft8_inv;
;; cgemm does not care.
;; Shared tile: element (r, c) at r * {RS} + c + c / 8.  Row steps put lanes on rows (32 rows per warp,
;; conflict-free for an odd stride); column steps put lanes on columns.  tw = W64^m for m < 64 (re ; im).
(def-type in-vec   (vector float :address-space :global :align :compact))
(def-type out-vec  (vector float :address-space :global :align :compact))
(def-type dims-vec (vector int   :address-space :global :align :compact))

(def-function splat (s)
  (declare #'(float => float4))
  ##(s s s s))
'''


def kernel_fwd():
    rows_a = step(14, "(+ (* row 73u) wq)", 9, False, twiddle_group="wq")
    rows_b = step(14, "(+ (* row 73u) (* wq 9u))", 1, False)
    cols_a = step(12, "(+ (* cg 73u) (coff (perm8 kx)))", 584, False, twiddle_group="cg")
    cols_b = step(12, "(+ (* cg 584u) (coff (perm8 kx)))", 73, False)
    return f'''
;; Forward: one workgroup per tile (mode 0: g = ci * NBT + tile) or filter (mode 1: g = co * C + ci).
(def-kernel fft8_fwd (src tw dims &out outr outi)
  (declare #'(in-vec in-vec dims-vec &out out-vec out-vec => nil)
           (global-size :derive-from outr :strategy :strided)
           (local-size  :set-to 256))
  (let ((C    (to-uint (~ dims 0)))
        (H    (to-uint (~ dims 1)))
        (K    (to-uint (~ dims 2)))
        (mode (~ dims 3))
        (NBT  (to-uint (~ dims 4)))
        (nt   (to-uint (~ dims 5)))
        (NBTP (to-uint (~ dims 6)))
        (V    (- 65u K))
        (NR   (if (= mode 0) 64u K))                ; rows that can be nonzero
        (re   (make-scratch-vector float 4672))     ; 64 x 73
        (im   (make-scratch-vector float 4672))
        (twr  (make-scratch-vector float 64))
        (twi  (make-scratch-vector float 64))
        (g    (to-uint (get-workgroup-id 0)))
        (tid  (to-uint (get-local-linear-id)))
        (lane (logand tid 31u))
        (wq   (shift-right tid 5u))
        (bt   (rem g NBT))
        (ntt  (* nt nt))
        (tt   (rem bt ntt))
        (y0   (* (/ tt nt) V))
        (x0   (* (rem tt nt) V))
        (base (if (= mode 0) (* (+ (* (/ bt ntt) C) (/ g NBT)) H H) (* g K K)))
        (obase (if (= mode 0) (* (+ (* (/ g NBT) NBTP) bt) 2112u) (* g 2112u))))
    (declare (uniform C H K mode NBT nt NBTP V NR))
    (when (< tid 64u)
      (set! (~ twr tid) (~ tw tid))
      (set! (~ twi tid) (~ tw (+ tid 64u))))
    (dotimes (j 16u)
      (let ((idx (+ tid (* j 256u)))
            (row (shift-right idx 6u))
            (cx  (logand idx 63u))
            (dst (+ (* row 73u) (coff cx))))
        (set! (~ re dst)
              (if (= mode 0)
                  (let ((gy (+ y0 row)) (gx (+ x0 cx)))
                    (if (and (< gy H) (< gx H)) (~ src (+ base (* gy H) gx)) 0.0))
                  (if (and (< row K) (< cx K)) (~ src (+ base (* row K) cx)) 0.0)))
        (set! (~ im dst) 0.0)))
    (sync-workgroup)
    ;; rows, step A: thread (row = lane + 32 rr, n2 = wq)
    (dotimes (rr 2u)
      (let ((row (+ lane (* rr 32u))))
        (when (< row NR)
{rows_a})))
    (sync-workgroup)
    ;; rows, step B: thread (row, k1 = wq)
    (dotimes (rr 2u)
      (let ((row (+ lane (* rr 32u))))
        (when (< row NR)
{rows_b})))
    (sync-workgroup)
    ;; columns kx = 0 .. 32 (at perm8(kx)), step A then B along y: thread (kx = lane, group = wq); kx 32: tid < 8
    (dotimes (cr 2u)
      (let ((kx (if (= cr 0u) lane 32u))
            (cg (if (= cr 0u) wq tid)))
        (when (or (= cr 0u) (< tid 8u))
{cols_a})))
    (sync-workgroup)
    (dotimes (cr 2u)
      (let ((kx (if (= cr 0u) lane 32u))
            (cg (if (= cr 0u) wq tid)))
        (when (or (= cr 0u) (< tid 8u))
{cols_b})))
    (sync-workgroup)
    (dotimes (j 9u)
      (let ((idx (+ tid (* j 256u))))
        (when (< idx 2112u)
          (let ((si (+ (* (/ idx 33u) 73u) (coff (perm8 (rem idx 33u))))))
            (set! (~ outr (+ obase idx)) (~ re si))
            (set! (~ outi (+ obase idx)) (if (= mode 0) (~ im si) (- (~ im si))))))))))
'''


def kernel_inv():
    cols_b = step(12, "(+ (* cg 584u) (coff (perm8 kx)))", 73, True, twiddle_group="cg")
    cols_a = step(12, "(+ (* cg 73u) (coff (perm8 kx)))", 584, True)
    rows_b = step(14, "(+ (* row 73u) (* wq 9u))", 1, True, twiddle_group="wq")
    rows_a = step(14, "(+ (* row 73u) wq)", 9, True)
    return f'''
;; Inverse: one workgroup per (co, tile), g = co * NBT + tile.  Columns B^-1, A^-1 along y; each kept row's
;; other half spectrum by symmetry; rows B^-1, A^-1 along x; write the V x V corner that did not wrap.
(def-kernel fft8_inv (yr yi tw dims &out Y)
  (declare #'(in-vec in-vec in-vec dims-vec &out out-vec => nil)
           (global-size :derive-from Y :strategy :strided)
           (local-size  :set-to 256))
  (let ((C    (to-uint (~ dims 0)))
        (H    (to-uint (~ dims 1)))
        (K    (to-uint (~ dims 2)))
        (NBT  (to-uint (~ dims 4)))
        (nt   (to-uint (~ dims 5)))
        (NBTP (to-uint (~ dims 6)))
        (V    (- 65u K))
        (O    (+ (- H K) 1u))
        (re   (make-scratch-vector float 4672))
        (im   (make-scratch-vector float 4672))
        (twr  (make-scratch-vector float 64))
        (twi  (make-scratch-vector float 64))
        (g    (to-uint (get-workgroup-id 0)))
        (tid  (to-uint (get-local-linear-id)))
        (lane (logand tid 31u))
        (wq   (shift-right tid 5u))
        (co   (/ g NBT))
        (bt   (rem g NBT))
        (ntt  (* nt nt))
        (tt   (rem bt ntt))
        (oy0  (* (/ tt nt) V))
        (ox0  (* (rem tt nt) V))
        (obase (* (+ (* (/ bt ntt) C) co) O O))
        (ibase (* (+ (* co NBTP) bt) 2112u)))
    (declare (uniform C H K NBT nt NBTP V O))
    (when (< tid 64u)
      (set! (~ twr tid) (~ tw tid))
      (set! (~ twi tid) (~ tw (+ tid 64u))))
    (dotimes (j 9u)
      (let ((idx (+ tid (* j 256u))))
        (when (< idx 2112u)
          (let ((di (+ (* (/ idx 33u) 73u) (coff (perm8 (rem idx 33u))))))
            (set! (~ re di) (~ yr (+ ibase idx)))
            (set! (~ im di) (~ yi (+ ibase idx)))))))
    (sync-workgroup)
    (dotimes (cr 2u)
      (let ((kx (if (= cr 0u) lane 32u))
            (cg (if (= cr 0u) wq tid)))
        (when (or (= cr 0u) (< tid 8u))
{cols_b})))
    (sync-workgroup)
    (dotimes (cr 2u)
      (let ((kx (if (= cr 0u) lane 32u))
            (cg (if (= cr 0u) wq tid)))
        (when (or (= cr 0u) (< tid 8u))
{cols_a})))
    (sync-workgroup)
    ;; rows 0 .. V-1: frequency kx = 33 .. 63 is the conjugate of frequency 64 - kx
    (dotimes (j 8u)
      (let ((idx (+ tid (* j 256u)))
            (row (/ idx 31u))
            (kx  (+ (rem idx 31u) 33u)))
        (when (< row V)
          (let ((dst (+ (* row 73u) (coff (perm8 kx))))
                (sr  (+ (* row 73u) (coff (perm8 (- 64u kx))))))
            (set! (~ re dst) (~ re sr))
            (set! (~ im dst) (- (~ im sr)))))))
    (sync-workgroup)
    (dotimes (rr 2u)
      (let ((row (+ lane (* rr 32u))))
        (when (< row V)
{rows_b})))
    (sync-workgroup)
    (dotimes (rr 2u)
      (let ((row (+ lane (* rr 32u))))
        (when (< row V)
{rows_a})))
    (sync-workgroup)
    (dotimes (j 16u)
      (let ((idx (+ tid (* j 256u)))
            (row (shift-right idx 6u))
            (px  (logand idx 63u))
            (oy  (+ oy0 row))
            (ox  (+ ox0 px)))
        (when (and (< row V) (< px V) (< oy O) (< ox O))
          (set! (~ Y (+ obase (* oy O) ox))
                (* (~ re (+ (* row 73u) (coff px))) 0.000244140625)))))))
'''


def form(src, name):
    """The text of top-level form `(def-kernel NAME ...` in src (; comments respected)."""
    i = src.index(f"(def-kernel {name} ")
    depth, j = 0, i
    while True:
        ch = src[j]
        if ch == ";":
            j = src.index("\n", j)
            continue
        depth += (ch == "(") - (ch == ")")
        if depth == 0 and ch == ")":
            return src[i:j + 1]
        j += 1


def kernel_cgemm2():
    """cgemm with 512-thread workgroups: warps 0-7 and 8-15 take two neighbouring 7-tile blocks of the same
    32 channels, so each Wf line fetched from L2 serves both (through L1).  Groups = 66 * nCG * ceil(nTB / 2);
    a block past the padded tile count idles."""
    k = form((HERE / "conv2d_fft.crisp").read_text(encoding="utf-8"), "cgemm")
    reps = [("(def-kernel cgemm ", "(def-kernel cgemm2 "),
            ("(local-size  :set-to 256)", "(local-size  :set-to 512)"),
            ("(nTB  (/ NBTP 7ul))", "(nTB  (/ (+ (/ NBTP 7ul) 1ul) 2ul))     ; workgroups along the tiles"),
            ("(co0  (+ (* cg 32ul) (* (shift-right tid 5ul) 4ul)))",
             "(co0  (+ (* cg 32ul) (* (logand (shift-right tid 5ul) 7ul) 4ul)))"),
            ("(t0   (* tb 7ul))", "(t0   (* (+ (* tb 2ul) (shift-right tid 8ul)) 7ul))"),
            ("(when (< co0 C)", "(when (and (< co0 C) (< t0 NBTP))")]
    for a, b in reps:
        assert k.count(a) == 1, a
        k = k.replace(a, b)
    return "\n;; " + "\n;; ".join(l.strip() for l in kernel_cgemm2.__doc__.splitlines()) + "\n" + k + "\n"


text = HEADER + DFT8 + kernel_fwd() + kernel_inv() + kernel_cgemm2()
(HERE / "conv2d_fft8.crisp").write_text(text, encoding="utf-8")
print(f"wrote conv2d_fft8.crisp ({len(text.splitlines())} lines)")
