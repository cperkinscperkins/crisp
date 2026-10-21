/*
 * crisp.h -- the Crisp compile API.                                   DRAFT (endeavour 190)
 *
 * Compile Crisp source strings to GPU kernels (SPIR-V or PTX), then ask about what came out:
 * which kernels, what arguments, where each argument goes.  The caller brings its own enqueue
 * code (Level Zero, CUDA, OpenCL, ...).
 *
 *     crisp_context* ctx = NULL;
 *     crisp_context_create("spv", &ctx);
 *     const char* flags[] = { "-DN=64", "--hardware-profile=bmg" };
 *     crisp_set_flags(ctx, flags, 2);
 *     crisp_add_source(ctx, my_kernel_source, "my_kernel.crisp");
 *     if (crisp_compile(ctx) != CRISP_OK) { fputs(crisp_diagnostics_text(ctx), stderr); ... }
 *     const void* bin; size_t bin_size;
 *     crisp_module_binary(ctx, 0, &bin, &bin_size);           // -> zeModuleCreate / cuModuleLoadData
 *     const char* entry = crisp_kernel_name(ctx, 0, 0);        // -> zeKernelCreate / cuModuleGetFunction
 *     ...
 *     crisp_context_destroy(ctx);
 *
 * CONVENTIONS
 *   - Every input (strings, the flags array) is COPIED during the call; free it whenever you like.
 *   - Every returned pointer is OWNED BY THE CONTEXT and stays valid until the next crisp_compile,
 *     crisp_clear_sources or crisp_context_destroy on that context.
 *   - Facts about results come from small getter functions, one value per call, not structs.  Easy
 *     from any FFI (ctypes, cffi, Rust, Java ...), and a new fact is a new function, so adding one
 *     never breaks the ABI.
 *   - A getter given a bad index (or called with no successful result) returns its "nothing" value:
 *     0 for counts, NULL for strings, the *_INVALID enumerator (always 0) for enums, CRISP_NO_SLOT for
 *     slots.  Calls that can fail for more interesting reasons return a crisp_status.
 *   - Indices are 0-based.  A module is addressed by its index; a kernel by (module, kernel); a
 *     parameter by (module, kernel, param); a physical argument slot by (module, kernel, slot).
 *     v1 always produces exactly ONE module per successful compile (A4); the index is there for
 *     def-orchestration, which will make it N.
 *
 * THREADS
 *   A context must not be used by two threads at once.  Different contexts may compile at the same
 *   time, in parallel.
 *
 * LIFETIME
 *   The compiler runs in separate helper process(es), started lazily by the first crisp_compile.
 *   Nothing needs initialising.  crisp_shutdown() stops them early (optional; they also stop when
 *   the calling process exits).  If a helper dies, that compile returns CRISP_ERROR_COMPILER_PROCESS
 *   and the next compile starts a fresh one.
 */
#ifndef CRISP_H
#define CRISP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#  if defined(CRISP_BUILDING_LIBRARY)
#    define CRISP_API __declspec(dllexport)
#  else
#    define CRISP_API __declspec(dllimport)
#  endif
#else
#  define CRISP_API __attribute__((visibility("default")))
#endif

/* ---------------------------------------------------------------------------------------------- */
/* Version                                                                                         */
/* ---------------------------------------------------------------------------------------------- */

#define CRISP_API_VERSION_MAJOR 0      /* bumped on an incompatible change */
#define CRISP_API_VERSION_MINOR 2      /* bumped when functions are added  */

/* The library's version as (major << 16) | minor.  A caller built against this header should
   check that the major matches CRISP_API_VERSION_MAJOR. */
CRISP_API uint32_t crisp_api_version(void);

/* ---------------------------------------------------------------------------------------------- */
/* Status                                                                                          */
/* ---------------------------------------------------------------------------------------------- */

typedef enum crisp_status {
    CRISP_OK                       = 0,
    CRISP_ERROR_COMPILE            = 1,  /* the source did not compile; see the diagnostics     */
    CRISP_ERROR_INVALID_ARGUMENT   = 2,  /* NULL pointer, bad index, unknown target, bad flag   */
    CRISP_ERROR_NO_RESULT          = 3,  /* asked about results before a successful compile     */
    CRISP_ERROR_IO                 = 4,  /* crisp_add_source_file could not read the file       */
    CRISP_ERROR_COMPILER_PROCESS   = 5,  /* the compiler helper could not start, or died        */
    CRISP_ERROR_OUT_OF_MEMORY      = 6,
    CRISP_ERROR_INTERNAL           = 7   /* a bug in Crisp; the diagnostics say more            */
} crisp_status;

/* A short constant English description of STATUS, e.g. "the source did not compile". */
CRISP_API const char* crisp_status_string(crisp_status status);

/* ---------------------------------------------------------------------------------------------- */
/* Context                                                                                         */
/* ---------------------------------------------------------------------------------------------- */

typedef struct crisp_context crisp_context;   /* opaque */

/* Creates a context for ONE target: "spv" or "ptx" (the --ir-target= values).  A context compiles
   to that target only (A4); make a second context for a second target. */
CRISP_API crisp_status crisp_context_create(const char* target, crisp_context** out_context);

/* Destroys the context and everything it owns.  NULL is allowed and does nothing. */
CRISP_API void crisp_context_destroy(crisp_context* context);

/* Sets the compile flags, exactly as crisp-compile takes them, e.g. "-DN=64",
   "--hardware-profile=bmg", "--differentiate", "--math-precision=fast".  REPLACES any earlier flags
   (it is not additive).  The flags are checked by the COMPILER, so a bad one surfaces from
   crisp_compile as CRISP_ERROR_INVALID_ARGUMENT with a diagnostic naming it: unknown flags, bad
   values, flags that name output files or hoisting (--hoist..., --metadata), --log-level, and
   --ir-target (the target is fixed at context creation).  This call itself fails only on NULLs. */
CRISP_API crisp_status crisp_set_flags(crisp_context* context, const char* const* flags, size_t count);

/* Adds Crisp source text (NUL-terminated, UTF-8).  VIRTUAL_NAME (e.g. "my_kernel.crisp") is what
   diagnostics call it; NULL gives "<source-N>".  Sources are compiled in the order added, as if
   they were one file -- so, as with the CLI, macros must be added before their uses. */
CRISP_API crisp_status crisp_add_source(crisp_context* context, const char* source, const char* virtual_name);

/* Reads a .crisp file and adds its text, named by PATH.  The file is read NOW, by the calling
   process: relative paths are relative to the CALLER's current directory. */
CRISP_API crisp_status crisp_add_source_file(crisp_context* context, const char* path);

/* Removes all sources (and the results of the last compile).  Flags are kept. */
CRISP_API crisp_status crisp_clear_sources(crisp_context* context);

/* Compiles every source added so far, with the current flags.  Blocks until done.  Replaces the
   results of any earlier compile on this context.  On CRISP_ERROR_COMPILE there are no modules,
   and the diagnostics say why.  Warnings can accompany CRISP_OK. */
CRISP_API crisp_status crisp_compile(crisp_context* context);

/* Stops the compiler helper process(es).  Optional.  Any later crisp_compile starts them again. */
CRISP_API void crisp_shutdown(void);

/* ---------------------------------------------------------------------------------------------- */
/* Diagnostics (errors, warnings) from the last crisp_compile                                      */
/* ---------------------------------------------------------------------------------------------- */

typedef enum crisp_severity {
    CRISP_SEVERITY_INVALID = 0,
    CRISP_SEVERITY_ERROR   = 1,
    CRISP_SEVERITY_WARNING = 2,
    CRISP_SEVERITY_NOTE    = 3
} crisp_severity;

CRISP_API size_t         crisp_diagnostic_count   (const crisp_context* context);
CRISP_API crisp_severity crisp_diagnostic_severity(const crisp_context* context, size_t index);
CRISP_API const char*    crisp_diagnostic_message (const crisp_context* context, size_t index);
/* The source's virtual name (or path); NULL when the diagnostic has no location. */
CRISP_API const char*    crisp_diagnostic_file    (const crisp_context* context, size_t index);
/* 1-based; 0 when unknown.  TODO(190): Crisp locates errors by FORM PATH today, not line/column. */
CRISP_API uint32_t       crisp_diagnostic_line    (const crisp_context* context, size_t index);
CRISP_API uint32_t       crisp_diagnostic_column  (const crisp_context* context, size_t index);

/* All diagnostics as one block of text, formatted the way crisp-compile prints them.  Never NULL
   (empty when there are none). */
CRISP_API const char*    crisp_diagnostics_text   (const crisp_context* context);

/* ---------------------------------------------------------------------------------------------- */
/* Modules: the compiled binaries                                                                  */
/* ---------------------------------------------------------------------------------------------- */

/* 0 until a compile succeeds; then 1 in v1. */
CRISP_API size_t crisp_module_count(const crisp_context* context);

/* The module's bytes: SPIR-V words for "spv", PTX text for "ptx".  For PTX the bytes are also
   NUL-terminated (the terminator is NOT counted in *OUT_SIZE), so they can go straight to
   cuModuleLoadData. */
CRISP_API crisp_status crisp_module_binary(const crisp_context* context, size_t module,
                                           const void** out_data, size_t* out_size);

/* ---------------------------------------------------------------------------------------------- */
/* Kernels                                                                                         */
/* ---------------------------------------------------------------------------------------------- */

CRISP_API size_t      crisp_kernel_count(const crisp_context* context, size_t module);

/* The entry-point name, as zeKernelCreate / cuModuleGetFunction want it.  With --differentiate a
   module holds each primal kernel followed by its "<name>_grad" kernel. */
CRISP_API const char* crisp_kernel_name (const crisp_context* context, size_t module, size_t kernel);

/* For a gradient kernel, the NAME of the primal kernel it differentiates; NULL for any other. */
CRISP_API const char* crisp_kernel_grad_of(const crisp_context* context, size_t module, size_t kernel);

/* ---------------------------------------------------------------------------------------------- */
/* Physical arguments -- what the launch API actually receives                                     */
/*                                                                                                 */
/* A kernel's PARAMETERS (below) are what the Crisp source declares.  Each one is lowered to one   */
/* or more physical argument SLOTS: a tensor becomes a pointer plus its offset, strides, extents   */
/* and length.  Slot I is the I-th argument to zeKernelSetArgumentValue / cuLaunchKernel.          */
/* ---------------------------------------------------------------------------------------------- */

typedef enum crisp_type {
    CRISP_TYPE_INVALID  = 0,
    CRISP_TYPE_CHAR     = 1,  CRISP_TYPE_UCHAR  = 2,
    CRISP_TYPE_SHORT    = 3,  CRISP_TYPE_USHORT = 4,
    CRISP_TYPE_INT      = 5,  CRISP_TYPE_UINT   = 6,
    CRISP_TYPE_LONG     = 7,  CRISP_TYPE_ULONG  = 8,
    CRISP_TYPE_HALF     = 9,  CRISP_TYPE_BFLOAT16 = 10,
    CRISP_TYPE_FLOAT    = 11, CRISP_TYPE_DOUBLE = 12,
    CRISP_TYPE_POINTER  = 13  /* a device pointer; see crisp_slot_address_space */
    /* TODO(190): vector scalars (float4 ...) passed by value, if a kernel boundary allows them. */
} crisp_type;

typedef enum crisp_address_space {
    CRISP_ADDRESS_SPACE_INVALID  = 0,
    CRISP_ADDRESS_SPACE_GLOBAL   = 1,
    CRISP_ADDRESS_SPACE_CONSTANT = 2,
    CRISP_ADDRESS_SPACE_LOCAL    = 3
} crisp_address_space;

#define CRISP_NO_SLOT ((size_t)-1)

CRISP_API size_t              crisp_slot_count        (const crisp_context* context, size_t module, size_t kernel);
CRISP_API crisp_type          crisp_slot_type         (const crisp_context* context, size_t module, size_t kernel, size_t slot);
/* Bytes the launch API expects for this slot (8 for a pointer on a 64-bit target). */
CRISP_API size_t              crisp_slot_size         (const crisp_context* context, size_t module, size_t kernel, size_t slot);
/* For a CRISP_TYPE_POINTER slot; CRISP_ADDRESS_SPACE_INVALID otherwise. */
CRISP_API crisp_address_space crisp_slot_address_space(const crisp_context* context, size_t module, size_t kernel, size_t slot);

/* ---------------------------------------------------------------------------------------------- */
/* Parameters -- what the Crisp source declared, and where each lands among the slots              */
/* ---------------------------------------------------------------------------------------------- */

typedef enum crisp_param_kind {
    CRISP_PARAM_INVALID = 0,
    CRISP_PARAM_SCALAR  = 1,   /* one slot, by value                                          */
    CRISP_PARAM_CELL    = 2,   /* a single element in device memory: pointer, byte size, offset */
    CRISP_PARAM_TENSOR  = 3,   /* vector / matrix / tensor: pointer, byte size, offsets, strides,
                                  extents, length                                               */
    CRISP_PARAM_RECORD  = 4    /* a def-record passed by value, one slot per field              */
} crisp_param_kind;

typedef enum crisp_direction {
    CRISP_DIRECTION_INVALID = 0,
    CRISP_DIRECTION_IN      = 1,
    CRISP_DIRECTION_OUT     = 2    /* an &out parameter */
} crisp_direction;

/* Parameters are in SLOT order and include the IMPLICIT ones -- scratch buffers the compiler added
   (from make-scratch-vector, make-scratch-cell ...) that the caller must still allocate and bind.
   crisp_param_purpose tells them apart. */
typedef enum crisp_purpose {
    CRISP_PURPOSE_INVALID    = 0,
    CRISP_PURPOSE_DECLARED   = 1,   /* written in the kernel's signature                         */
    CRISP_PURPOSE_SCRATCH    = 2,   /* implicit scratch: allocate it, bind it, never read it back */
    CRISP_PURPOSE_DEBUG_LOG  = 3,   /* implicit debug log: reported, not yet supported by the API */
    CRISP_PURPOSE_TENSOR_MAP = 4    /* implicit TMA descriptor (CUDA): reported, not yet supported */
} crisp_purpose;

CRISP_API size_t           crisp_param_count       (const crisp_context* context, size_t module, size_t kernel);
CRISP_API crisp_purpose    crisp_param_purpose     (const crisp_context* context, size_t module, size_t kernel, size_t param);
/* Nonzero when the buffer must be ZEROED before EVERY launch: global scratch (reductions keep
   counters in it, which the kernel leaves non-zero).  Workgroup-local scratch never needs it. */
CRISP_API int              crisp_param_zero_before_launch(const crisp_context* context, size_t module, size_t kernel, size_t param);
CRISP_API const char*      crisp_param_name        (const crisp_context* context, size_t module, size_t kernel, size_t param);
CRISP_API crisp_param_kind crisp_param_kind_of     (const crisp_context* context, size_t module, size_t kernel, size_t param);
CRISP_API crisp_direction  crisp_param_direction   (const crisp_context* context, size_t module, size_t kernel, size_t param);
/* The element type of a cell or tensor; the type itself for a scalar. */
CRISP_API crisp_type       crisp_param_element_type(const crisp_context* context, size_t module, size_t kernel, size_t param);
/* Number of dimensions of a tensor (1 = vector, 2 = matrix ...); 0 for anything else. */
CRISP_API uint32_t         crisp_param_rank        (const crisp_context* context, size_t module, size_t kernel, size_t param);
/* The tensor layout the kernel's author declared (the def-type's :align), i.e. what the caller must
   hand it.  The author picks it; this call reports it so the caller does not have to guess.
     COMPACT        -- the FAST path: the kernel indexes by extents alone, with no offset or stride
                       reads.  Give it dense, row-major data starting at the pointer (in PyTorch
                       terms: a contiguous tensor -- call .contiguous() on a view first).  Offset
                       and stride slots must still be set, but the kernel does not read them.
     COMPACT_OFFSET -- dense like COMPACT, plus the per-axis offsets are honoured.
     STRIDED        -- offsets and strides both honoured: pass a view's strides and storage offset
                       straight through, no copy.  Write the kernel this way to accept any view.
   CRISP_LAYOUT_INVALID for anything but a tensor. */
typedef enum crisp_layout {
    CRISP_LAYOUT_INVALID        = 0,
    CRISP_LAYOUT_COMPACT        = 1,
    CRISP_LAYOUT_COMPACT_OFFSET = 2,
    CRISP_LAYOUT_STRIDED        = 3
} crisp_layout;

CRISP_API crisp_layout     crisp_param_layout      (const crisp_context* context, size_t module, size_t kernel, size_t param);

/* Its device address space (cell / tensor); CRISP_ADDRESS_SPACE_INVALID for scalars and records. */
CRISP_API crisp_address_space crisp_param_address_space(const crisp_context* context, size_t module, size_t kernel, size_t param);

/* In a gradient kernel: the NAME of the primal parameter this one is the adjoint of, else NULL.
   An IN adjoint carries the incoming gradient (of an &out); an OUT adjoint receives the computed
   gradient (of an input).  A scalar's gradient comes back through memory, as an OUT cell.
   A user's own parameter that merely ends in "_grad" is never reported as an adjoint. */
CRISP_API const char*      crisp_param_adjoint_of  (const crisp_context* context, size_t module, size_t kernel, size_t param);

/* WHERE does each part of a parameter go?  Ask by role instead of knowing Crisp's slot layout:
       crisp_param_slot(ctx, m, k, p, CRISP_ROLE_STRIDE, 1)   -> the slot for axis 1's stride.
   AXIS is used by OFFSET / STRIDE / EXTENT on a tensor (0 .. rank-1) and by FIELD on a record;
   pass 0 otherwise.  Returns CRISP_NO_SLOT when the parameter has no such part.
   Units: BYTE_SIZE is in bytes; OFFSET, STRIDE, EXTENT and LENGTH are in ELEMENTS.  A strided
   access reads element  sum over k of (offset[k] + index[k] * stride[k])  -- the offsets are per
   axis and SUMMED (src/analysis/structs.lisp %build-tensor-flat-index-form).  See crisp_param_layout
   for which of them a given kernel reads at all. */
typedef enum crisp_role {
    CRISP_ROLE_INVALID   = 0,
    CRISP_ROLE_VALUE     = 1,  /* a scalar's only slot                    */
    CRISP_ROLE_POINTER   = 2,  /* cell / tensor: the device pointer       */
    CRISP_ROLE_BYTE_SIZE = 3,  /* cell / tensor: the allocation size      */
    CRISP_ROLE_OFFSET    = 4,  /* cell: AXIS 0; tensor: per axis          */
    CRISP_ROLE_STRIDE    = 5,  /* tensor, per axis                        */
    CRISP_ROLE_EXTENT    = 6,  /* tensor, per axis                        */
    CRISP_ROLE_LENGTH    = 7,  /* tensor: total element count             */
    CRISP_ROLE_FIELD     = 8   /* record: field AXIS                      */
} crisp_role;

CRISP_API size_t crisp_param_slot(const crisp_context* context, size_t module, size_t kernel, size_t param,
                                  crisp_role role, uint32_t axis);

/* ---------------------------------------------------------------------------------------------- */
/* PLANNED -- added as the source-mode dogfood hoist needs them (A3), documented as they land:     */
/*   - scratch allocation sizes (some depend on launch geometry) -- via the launch object          */
/*   - the debug log buffer, tensor-map descriptors                                                */
/*   - launch geometry: global / local size, number of groups -- likely a call that takes the     */
/*     argument values and returns the grid, since sizes can be :derive-from arguments             */
/* ---------------------------------------------------------------------------------------------- */

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif /* CRISP_H */
