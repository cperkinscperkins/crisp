# Branded Types - Implementation Plan

## Overview

Branded types introduce **dependent types** into Crisp's otherwise static type system.
A `brand` declaration inside a `def-struct` or `def-record` creates a type that is tied to
a specific *instance* of that struct/record. This allows the compiler to distinguish
`(token-t s1)` from `(token-t s2)` even when `s1` and `s2` are the same struct type.

The design document is: `docs/chapters/10_storage_handle_types/20_derived_types.md` (section "Branded Types").

## Design Approach

### Reuse the Derived Type DAG

Branded types reuse the existing `type-node` and `*type-derivation-graph*` infrastructure.
A branded type IS a derived type, with extra metadata. The substitution rules (`:no`, `:equal`,
`:descendant`, `:ancestor`) work identically.

When a variable is bound to a branded struct instance, a **gensym'd type node** is created
for each of that struct's brands. For example, if `server` has `(brand token-t ulong :subst :no)`,
then `(let ((s1 (make-server ...)))` creates a type node with a gensym'd name like `#:TOKEN-T-42`,
tied to `s1`. This node has:

- `type-name`: the gensym'd symbol (unique per instance)
- `original-type`: `ulong` (the backing type)
- `base-type`: `ulong`
- `subst-mode`: `:no` (from the brand declaration)
- NEW `brand-name`: `TOKEN-T` (the user-facing name, shared across instances)
- NEW `brand-owner`: reference to the variable `s1`

Two gensym'd nodes for different instances (`#:TOKEN-T-42` for `s1`, `#:TOKEN-T-87` for `s2`) are
distinct types in the DAG. This is what makes `(token-t s1)` incompatible with `(token-t s2)`.

### Aliasing

When a variable is aliased (`(let ((s2 s1)) ...)`), the alias gets the **same** gensym'd brand
types as the original. They refer to the same value, so they share the same brand identity.

### Enforcement Modes

- `:enforce :always` - branded types are always active and enforced
- `:enforce :diff` (default) - branded types only active when compiling with `--differentiate` flag;
  otherwise they decay to the base type

### Data Architecture: Two Tables

Brand state is split across two levels, matching the compiler's existing architecture
(`session.lisp`):

**Table 1: Brand Definitions (`*brand-definitions*` - global)**

A global hash table (like `*type-derivation-graph*`, `*crisp-structs*`). Populated when
`def-struct` / `def-record` is processed. Persists for the entire compilation.

Maps `(brand-name, struct-type)` to a brand definition record containing:
- base type (e.g., `ulong`)
- subst mode (`:no`, `:equal`, `:descendant`, `:ancestor`)
- enforce mode (`:always` or `:diff`)
- owning struct name

This is the "what does `token-t` mean for a `server`?" lookup. Multiple structs can register
the same brand name (e.g., both `server` and `virtual-server` can have `token-t`), keyed by
the pair.

**Table 2: Brand Instance Cache (new slot on `compiler-context` - per-function)**

A hash table on `compiler-context`, scoped to the current function being analyzed.

Maps `(brand-name, variable-identity)` to the gensym'd type name. This is the memoization
cache for `resolve-brand-type`.

When analysis begins on a new function, the context is fresh, so the cache is empty - exactly
the right scoping. Within a function, `(token-t s)` hits the cache and returns the same
gensym consistently. When analysis moves to the next function, those gensyms are gone.

```
(defstruct compiler-context
  ...existing slots...
  (brand-instance-cache nil :type (or null hash-table)))
```

### Brand Resolution (`resolve-brand-type`)

A single Common Lisp function used by the compiler during analysis. NOT a Crisp function,
NOT a per-brand defun. One function, table-driven dispatch.

```lisp
(defun resolve-brand-type (brand-name var-ref var-type)
  "Resolves a branded type reference like (token-t s).
   Looks up the brand definition by (brand-name, var-type) in *brand-definitions*.
   Checks the brand instance cache on *compiler-context* for an existing gensym.
   If none, gensyms a new type name, registers a DAG node, caches it, returns it."
  ...)
```

Flow:
1. Look up `(brand-name, var-type)` in `*brand-definitions*` to get the brand spec
2. Validate that var-type is a struct that actually declares this brand (error otherwise)
3. Check `brand-instance-cache` on `*compiler-context*` for `(brand-name, var-ref)`
4. If cache miss: gensym a new type name, register a `type-node` in the DAG (with the
   brand's base type, subst mode, plus brand-name and owner in new slots), cache it
5. Return the gensym'd type name

## Prerequisites

### `--differentiate` CLI flag

A new compiler flag `--differentiate` must be added. For now it has no effect on anything
except branded type enforcement. Many tests use `TEST-WITH[--differentiate]` to test both modes.

### Test runner directives

Verify that `TEST-WITH[--differentiate]` and `FAIL-WITH[--differentiate]` work in the test
harness. If not, extend the directive system to support arbitrary flags.

## Test-by-Test Implementation Notes

### Test 01: `01-in-struct.crisp` - Basic Parsing & Construction

```lisp
(def-struct server
  (brand token-t ulong :subst :no)
  (active-token token-t)
  (id int))

(def-function instantiate-server ()
    (declare (return-type int))
  (let ((s (make-server :active-token 12345 :id 1)))
    (id~ s)))
```

**What the compiler must do:**

**A. Separate brands from members during parsing.**
In `def-struct` (macros.lisp ~line 589), before calling `parse-struct-member-spec`, filter out
forms whose `car` is `brand`. Parse these separately.

**B. Register the branded type.**
`token-t` is registered as a derived type of `ulong` with `:subst :no`. This reuses
`register-derived-type` (or a variant). The brand definition (owning struct, enforce mode,
base type, subst mode) is stored in `*brand-definitions*` keyed by `(token-t, server)`.

**C. Members reference the brand as a type.**
`(active-token token-t)` is a normal member whose type is `token-t`. Since `token-t` is now
registered as a valid type (from step B), existing layout computation and accessor generation
should work unchanged.

**D. Constructor implicit promotion.**
`(make-server :active-token 12345 :id 1)` passes a `ulong` literal for a `token-t` member.
With `:subst :no`, a raw `ulong` normally can't pass for `token-t`. BUT the constructor is
special: it is the *birthplace* of branded values. There is no instance yet to brand against,
so the cast must be implicit.

The constructor (or type checker at the `make-server` call site) must recognize branded member
types and accept values of the base type, performing an implicit promotion. This is the ONE
place where `:subst :no` is relaxed.

---

### Test 03: `03-struct-and-function-signatures.crisp` - Dependent Types

```lisp
;; dependent argument type
(def-function authenticate (s tok)
  (declare #'(server (token-t s) => int))
  1)

;; dependent return type
(def-function retrieve-token (s)
    (declare #'(server => (token-t s)))
    (active-token~ s))

;; type loss - brand can't escape local scope
(def-function lost-type ()
    (declare (return-type ulong))
  (let ((s (make-server :active-token 12345 :id 1)))
    (as ulong (active-token~ s))))
```

**What the compiler must do:**

**A. Parse dependent type specifiers in declarations.**
`(token-t s)` in a function signature is a **type function application** - the brand name
applied to a parameter. The declaration parser must recognize this form and store the dependency
(i.e., "second argument's type is `token-t` branded by the first argument `s`").

**B. Property accessors propagate brand info.**
`(active-token~ s)` must return a value typed as `(token-t s)` - not just `token-t` in the
abstract, but branded to the specific variable `s`. This means the accessor analysis needs to
know that `active-token` is a branded member and tag the result with `s`'s brand context.

**C. Call-site signature matching.**
When calling `(authenticate s1 my-token)`, the compiler resolves the dependent signature:
1. First arg is `s1` (type: `server`)
2. Signature says second arg must be `(token-t <first-param>)`, i.e., `(token-t s1)`
3. Check that `my-token`'s branded type matches `(token-t s1)`

**D. Dependent return types.**
`retrieve-token` declares return type `(token-t s)`. The compiler must verify that the
function body actually returns a value of that branded type (tied to parameter `s`).

**E. Type loss and explicit casting.**
When a struct is created locally, the brand is scoped to that local variable. There is no
syntax to express a dependent return type for a local variable. The user must explicitly cast
to the base type with `(as ulong ...)`. The compiler must accept this cast.

---

## Resolved Decisions

1. **Where to store brand metadata?**
   Two tables: `*brand-definitions*` (global, keyed by brand-name + struct-type) for the
   definitions, and a `brand-instance-cache` slot on `compiler-context` (per-function) for
   the gensym memoization. The `type-node` struct gets two new slots: `brand-name` and
   `brand-owner`.

2. **Brand as type function.**
   A single `resolve-brand-type` CL function, called by the compiler during analysis.
   Table-driven dispatch via `*brand-definitions*`, memoized via `compiler-context`.
   Not a per-brand defun, not a defgeneric.

3. **Constructor promotion.**
   Constructors implicitly promote base-type values to branded types. This is the ONE place
   where `:subst :no` is relaxed, because the struct instance doesn't exist yet at
   construction time.

## Open Questions

1. **Negative test gap.** Passing an invalid value to the type function (e.g., `(token-t 42)`
   or `(token-t some-unrelated-struct)`) should be a compilation error. We should add an
   error test for this.

2. **When exactly are gensym'd type nodes created?** At analysis time when a `let` binding
   creates a struct instance? When a function parameter is typed as a branded struct? Both?
   Likely both - any time a variable of a branded struct type comes into scope.

3. **CI integration.** A full `--differentiate` pass of all tests will be added. The mechanism
   is straightforward but details TBD.

4. **Memoization key for aliasing.** When `(let ((s2 s1)) ...)`, `s2` should share `s1`'s
   brand identity. The cache key needs to be a "value identity" that aliases inherit, not
   just the variable name. Exact representation TBD.
