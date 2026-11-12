;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)
;; EMPTY as of 2026-11-11 -- validate-ptx-tcgen05-acc-ring / -qint-ring (the "], 512;" needle),
;; endeavour 213's validate-ptx-tcgen05-transb(-ring) and endeavour 215's
;; validate-ptx-tcgen05-vector-stores-f32 / -f16 folded into tests/run-specs.lisp.
;; EMPTY as of 2026-11-11 -- endeavours 211 / 212's validators (%211-helper-names,
;; validate-ptx-211-shift-rotate, validate-spv-211-helpers-noinline, validate-ptx-212-vote,
;; validate-spv-212-vote) folded into tests/run-specs.lisp.
;; EMPTY as of 2026-11-09 -- endeavour 210's validators (validate-ptx-tma-grid-constant,
;; validate-ptx-transform-scale3, validate-ptx-wgmma-store-pairs-only) folded into tests/run-specs.lisp.
;; EMPTY as of 2026-11-06 -- endeavour 208's tcgen05 validators folded into tests/run-specs.lisp.
;; EMPTY as of 2026-11-04 -- endeavour 207's sync int8 validators folded into tests/run-specs.lisp.
;; EMPTY as of 2026-11-02 -- BUG 135's validators folded into tests/run-specs.lisp.
;; EMPTY as of 2026-10-30 -- endeavours 200 / 201 folded into tests/run-specs.lisp: %200-helper-names,
;; validate-ptx-200-helpers-inline, validate-spv-200-helpers-noinline (before main); %vad-resolve-symbolic-size
;; (:match-global-size) replaced in place.
;; EMPTY as of 2026-10-29 -- endeavours 196-199's validators folded into tests/run-specs.lisp.
