User Derived Types mean we now have type trees. "type loops" and "type recursion" are disallowed, and the type deriviation declarations do not support multipass semantics - meaning that for any 

`(def-derived-type NEW ORIG :subst :v)` , the `ORIG` type MUST exist already, else a compile error.

This, for example, should error:
```
(def-derived-type coordinate point :subst :equal)
(def-struct point (x int) (y int))
```
whereas if the two expressions were in reverse order, it'd be fine. 


IMPLEMENTATION
==============

Each of the three numeric type classes (signed integers, unsigned integers, floating points) will need to be its own DAG prepopulated with the numeric types Crisp supports.

QUESTION: what about the machine vector types like float4 etc? 


Additionaly, there will have to be a "collection" of struct DAGs for types derived from structs.
And a collection of record DAGs for types derived from def-record.

Obviously, the Compiler itself will likely need some helper routines like `find-common-ancestor` and `is-type-in-DAG`, `is-type-derived-from?` `is-type-ancestor-to?` .  
There is a `(is-substitutable-for? substT baseT)` in the design doc for users. We don't  have type constraints supported yet. 





# def-derived-type Implementation Plan

## Overview

Implementing the `def-derived-type` feature to support user-defined type derivation with substitution rules and type hierarchies. This enables custom type overloading, arithmetic dominance, and type-safe derivation for structs, records, and scalars.

**Design Document**: `docs/chapters/10_storage_handle_types/20_derived_types.md`
**Test Directory**: `tests/spec/031-def-derived-type/`
**Implementation Notes**: `tests/spec/031-def-derived-type/derived-type-dag.md`

---

## Type Node Structure

```lisp
(defstruct type-node
  "Represents a type in the derivation hierarchy (DAG)."
  (type-name nil :type symbol)       ; e.g., 'meters', 'point', 'int'
  (original-type nil :type symbol)   ; Immediate parent in derivation (nil for real types)
  (base-type nil :type symbol)       ; Root "real" type (memoized for fast lookup)
  (subst-mode nil :type symbol)      ; :descendant, :ancestor, :equal, :no (nil for real types)
  (ancestors nil :type list)         ; Immediate more-general types
  (descendants nil :type list))      ; Immediate more-specific types

(defvar *type-derivation-graph* (make-hash-table)
  "Maps type-name -> type-node for all types (real and derived).")
```

### Key Design Decisions

1. **One structure for all types**: Both "real" types (float, structs) and derived types share the same node structure.
2. **`base-type` memoization**: Computed once when node is created by following `original-type` chain to root. Avoids repeated walks.
3. **Immediate relationships only**: `ancestors` and `descendants` lists contain only immediate neighbors. Transitivity is handled by graph walking.
4. **Cycle detection required**: `:equal` creates bidirectional edges (cycles). All graph walks must track visited nodes.

---

## Core Algorithms

### Creating Derived Types: `(def-derived-type NEW ORIG :subst MODE)`

#### Case 1: `:descendant` (NEW is more specific than ORIG)
```lisp
;; NEW can substitute for ORIG
;; NEW sits BELOW ORIG in hierarchy

1. Create NEW node:
   - original-type = ORIG
   - base-type = ORIG.base-type (or ORIG if ORIG is real)
   - subst-mode = :descendant
   - ancestors = [ORIG]
   - descendants = []

2. Update ORIG node:
   - descendants.add(NEW)
```

#### Case 2: `:ancestor` (NEW is more general than ORIG)
```lisp
;; ORIG can substitute for NEW
;; NEW sits ABOVE ORIG in hierarchy

1. Create NEW node:
   - original-type = ORIG
   - base-type = ORIG.base-type (or ORIG if ORIG is real)
   - subst-mode = :ancestor
   - ancestors = []
   - descendants = []

2. Update ORIG node:
   - ancestors.add(NEW)
```

#### Case 3: `:equal` (NEW and ORIG are interchangeable)
```lisp
;; Both can substitute for each other
;; Creates CYCLE in graph!

1. Create NEW node:
   - original-type = ORIG
   - base-type = ORIG.base-type
   - subst-mode = :equal
   - ancestors = [ORIG]
   - descendants = [ORIG]

2. Update ORIG node:
   - ancestors.add(NEW)
   - descendants.add(NEW)
```

#### Case 4: `:no` (No substitution)
```lisp
;; No hierarchy relationship
;; But still tracks derivation for finding "real" type

1. Create NEW node:
   - original-type = ORIG (for finding struct/scalar definition)
   - base-type = ORIG.base-type
   - subst-mode = :no
   - ancestors = []
   - descendants = []

2. Do NOT update ORIG node's lists
```

### Substitutability Check

```lisp
(defun is-substitutable-for? (source-type target-type)
  "Can source-type be used where target-type is expected?
   Returns T if source can substitute for target."
  (or (eq source-type target-type)
      (has-ancestor-path? source-type target-type (make-hash-table))))

(defun has-ancestor-path? (from-type to-type visited)
  "Walk UP through ancestors from FROM-TYPE to find TO-TYPE.
   Detects cycles using VISITED hash table."
  (when (gethash from-type visited)
    (return-from has-ancestor-path? nil)) ; Already visited (cycle)

  (setf (gethash from-type visited) t)

  (let ((node (gethash from-type *type-derivation-graph*)))
    (when node
      (dolist (ancestor (type-node-ancestors node))
        (when (or (eq ancestor to-type)
                  (has-ancestor-path? ancestor to-type visited))
          (return-from has-ancestor-path? t)))))
  nil)
```

### Dominance Resolution (for arithmetic operations)

```lisp
(defun resolve-dominance (type-a type-b)
  "Determines which type dominates in arithmetic operations.
   Returns the dominant type, or NIL if they cannot mix."
  (cond
    ((eq type-a type-b) type-a)

    ;; Check if either can substitute for the other
    ((is-substitutable-for? type-a type-b) type-b)  ; B is more general
    ((is-substitutable-for? type-b type-a) type-a)  ; A is more general

    ;; Both are derived from common base - check dominance rules
    ((have-common-base? type-a type-b)
     (resolve-common-base-dominance type-a type-b))

    ;; Fall back to category + size promotion (existing logic)
    (t (get-promoted-type-by-category type-a type-b))))
```

**Dominance Rules** (from design doc lines 119-177):
- `:ancestor` is **Dominant** - asserts itself in arithmetic
- `:descendant` is **Recessive** - yields to base type
- `:equal` is **Recessive**
- Two `:ancestor` types from same base (different types) → **ERROR**
- Two `:descendant` types from same base → return **base**
- `:ancestor` + `:descendant` from same base → return **:ancestor** type

---

## Implementation Phases

### Phase 1: Infrastructure (Replace Numeric Promotion)
**Goal**: Replace current size-based type promotion with DAG-based system.

**Files**:
- `src/types/hierarchy.lisp` (new)
- `src/type-checker.lisp` (modify)

**Tasks**:
1. Create `type-node` structure and `*type-derivation-graph*`
2. Prepopulate built-in numerics:
   - Signed: `char -> short -> int -> long`
   - Unsigned: `uchar -> ushort -> uint -> ulong`
   - Float: `half -> float -> double` (and `bfloat16` parallel to `half`)
3. Implement `is-substitutable-for?` with cycle detection
4. Replace `get-promoted-type` to use DAG traversal instead of size comparison
5. Run existing tests in `tests/spec/002-type-conversion/` to validate

**Note**: All built-in numerics have `original-type=nil` and `base-type=type-name` (they are real types). They are linked via `ancestors`/`descendants` relationships.

### Phase 2: def-derived-type Macro
**Goal**: Implement the core language feature.

**Files**:
- `src/macros.lisp` (add macro)
- `src/types/hierarchy.lisp` (add registration function)

**Tasks**:
1. Implement `def-derived-type` macro skeleton
2. Validate original type exists at macro-expansion time (single-pass requirement)
3. Create `register-derived-type` function that:
   - Computes `base-type` by walking `original-type` chain
   - Creates new `type-node`
   - Updates ancestor/descendant relationships based on `subst-mode`
4. Use `eval-when` for load-time registration (similar to `def-struct`)
5. Error if original type doesn't exist (test: `037-single-pass-semantics.crisp`)

**Validation Tests**:
- `034-spoke-wheel-types.crisp` - basic derivation tree
- Error: `037-single-pass-semantics.crisp`

### Phase 3: Constructor & Casting Functions
**Goal**: Auto-generate `make-XXXX`, `as-XXXX`, `is-XXXX?` functions.

**Files**: `src/macros.lisp` (extend def-derived-type)

**Tasks**:
1. Generate `make-<derived>` macro for structural types (structs, records):
   ```lisp
   (defmacro make-meters (&rest args)
     `(as-meters (make-float ,@args)))
   ```
   - Skip for scalar-derived types (use `as-` instead)

2. Generate `as-<original>` and `as-<derived>` casting functions:
   ```lisp
   (defmacro as-meters (val) `(%cast-derived ',meters ',float ,val))
   (defmacro as-float (val) `(%cast-derived ',float ',meters ,val))
   ```

3. Generate `is-<derived>?` type predicate:
   ```lisp
   (defun is-meters? (type-spec)
     (or (eq type-spec 'meters)
         (and (consp type-spec) (eq (first type-spec) 'meters))))
   ```

**Validation Tests**:
- `09-derived-make-XXXX.crisp` (structs)
- `28-derived-record-make-XXXX.crisp` (records)

### Phase 4: Function Resolution & Overloading
**Goal**: Use substitutability in function dispatch.

**Files**: `src/type-checker.lisp`

**Tasks**:
1. Update `types-compatible-p` to call `is-substitutable-for?`:
   ```lisp
   (or (types-equivalent-p arg-type param-type)
       (is-substitutable-for? arg-type param-type)
       ;; ... existing special cases
   ```

2. Update `resolve-best-signature` to prefer exact matches over substitutable matches

3. Detect ambiguous calls:
   - Multiple `:equal` types both match → error
   - Multiple substitutable paths of equal length → error

**Validation Tests**:
- `01-derived-no-subst-struct.crisp` - no substitution
- `03-derived-equal-subst-struct.crisp` - bidirectional substitution
- `05-derived-descendant-struct.crisp` - derived can sub for original
- `07-derived-ancestor-struct.crisp` - original can sub for derived
- `20-26-*-record.crisp` - same tests for records
- Errors: `01-no-means-no-subst.crisp`, `03-no-subst.crisp`, `05-equal-does-not-mena-yes.crisp`, `07-ancestor-not-subst-for-descendant.crisp`

### Phase 5: Arithmetic Dominance
**Goal**: Implement dominance rules for derived numeric types.

**Files**:
- `src/type-checker.lisp` (extend `get-promoted-type`)
- `src/analysis/ops.lisp` (modify binary op analyzers if needed)

**Tasks**:
1. Implement helper functions:
   ```lisp
   (defun have-common-base? (type-a type-b))
   (defun find-common-ancestor (type-a type-b))
   (defun resolve-common-base-dominance (type-a type-b))
   ```

2. Update `get-promoted-type` to handle derived types:
   - Check if same type → return it
   - Check substitutability (one dominates) → return dominant
   - Check common base → apply dominance rules
   - Fall back to category + size (existing logic)

3. Implement dominance rules:
   - Both `:descendant` from same base → return base
   - Both `:ancestor` from same base (different) → ERROR
   - `:ancestor` + `:descendant` → return `:ancestor`
   - Built-in hierarchy → return more general type

**Validation Tests**:
- `030-derived-numeric-types.crisp` - basic dominance
- `032-iron-steel.crisp` - mixed hierarchy
- `036-derived-numeric-tree.crisp` - multi-level derivation
- Errors: `31-dominant-no-mix.crisp`, `033-impossible-forge.crisp`, `035-diamond.crisp`

### Phase 6: Property Accessor Overloading
**Goal**: Allow custom property accessors for derived struct/record types.

**Files**: `src/analysis/structs.lisp`

**Tasks**:
1. Modify property accessor resolution to check for overloaded accessors based on derived type
2. If no overload found, fall back to base type accessor
3. Ensure accessor functions use substitutability check

**Validation Tests**:
- `11-derived-overload-prop-acc.crisp`

### Phase 7: Metadata Integration
**Goal**: Include derived types and their base types in metadata.

**Files**: `src/metadata.lisp`

**Tasks**:
1. Modify `collect-kernel-dependencies` to:
   - When encountering a derived type on kernel boundary, walk to base type
   - Add base struct/record to dependencies

2. Update `serialize-structs` to include comment about derived type usage (optional)

**Validation Tests**:
- `13-derived-type-in-metadata.crisp` - base struct included
- `15-derived-type-tree-metadata.crisp` - multiple levels

### Phase 8: Error Handling & Edge Cases
**Goal**: Comprehensive error messages and validation.

**Tasks**:
1. Detect invalid original types:
   - Function types → error (tests: `09-illegal-function.crisp`, `10-illegal-function.crisp`)
   - Non-existent types → error (already handled in Phase 2)

2. Clear error messages for:
   - Substitution failures ("Type X cannot be used where Y is expected")
   - Diamond problems ("Cannot mix dominant types X and Y")
   - Ambiguous overload resolution

3. Add validation to prevent `def-derived-type` inside `with-template-type`
   - **TODO**: Add error test for this case
   - Template creation should reject child form

---

## Testing Strategy

1. **Update `tests/ci-stop.txt`** to `031-def-derived-type`
   - This adds entire directory to test run
   - Tests will fail until features are implemented - that's expected!

2. **Phase-by-phase validation**:
   - After Phase 1: Run `002-type-conversion` tests
   - After each subsequent phase: Run relevant `031-def-derived-type` tests
   - Use `sbcl --script tests/run-specs.lisp` for E2E tests
   - Use `sbcl --load tests/run-ci.lisp` for unit tests

3. **TDD approach**: Implement feature, run tests, fix issues, repeat

---

## Open Questions & Future Work

### Deferred Features
- **`set-derived`** (lines 180-246 in design doc): Creating hierarchies between existing struct types. Defer to later.

### Notes
- **Template interaction**: `def-derived-type` cannot be wrapped by `with-template-type` (design doc line 34). Need to add validation and error test.
- **bfloat16 placement**: Parallel to `half` in float hierarchy (both 16-bit floats).
- **Machine vector types** (float4, etc.): Not addressed in this phase. Future work.

---

## Files to Create/Modify

### New Files
- `src/types/hierarchy.lisp` - Type node structure, graph, helpers

### Modified Files
- `src/types/registry.lisp` - Add `*type-derivation-graph*` initialization
- `src/macros.lisp` - Add `def-derived-type` macro
- `src/type-checker.lisp` - Update promotion and compatibility
- `src/analysis/ops.lisp` - Update arithmetic operators (if needed)
- `src/analysis/structs.lisp` - Property accessor overloading
- `src/metadata.lisp` - Derived type dependencies
- `tests/ci-stop.txt` - Update to `031-def-derived-type`

---

## Definition of Done (per feature)

- [ ] Feature implemented
- [ ] Relevant tests passing
- [ ] Error cases handled with clear messages
- [ ] Logging added (using log4cl)
- [ ] Doc strings on all functions
- [ ] No regression in existing tests
- [ ] Code reviewed and approved

---

**Started**: 2025-02-05
**Status**: Phase 1 - In Progress
