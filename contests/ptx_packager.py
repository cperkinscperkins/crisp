"""
Shared PTX to CUDA C++ inline assembly packager for Crisp contest entries.

Provides a unified, robust conversion from LLVM-emitted PTX entries to
CUDA C++ `asm volatile(...)` blocks for inline inclusion in competition submissions.
"""

from __future__ import annotations

import re


LLVM_REG_PATTERN = re.compile(r"%(rd|rs|r|fd|f|p|h|hh)(\d+|<[0-9]+>)")


def prefix_ptx_registers(text: str, prefix: str = "cr_") -> str:
    """
    Prefixes all LLVM NVPTX virtual registers with a unique namespace (e.g. `%cr_rd...`).

    Matches LLVM's exact register classes (`%(rd|rs|r|fd|f|p|h|hh)` followed by digits
    or `<N>` declaration ranges). This completely avoids NVCC outer parameter register
    shadowing (BUG-001) while leaving all hardware/special registers (`%ctaid`, `%ntid`,
    `%tid`, `%laneid`, `%lanemask_*`, `%globaltimer`, `%cluster_*`, `%dynamic_smem_size`,
    etc.) untouched.
    """
    return LLVM_REG_PATTERN.sub(rf"%{prefix}\1\2", text)


_MODULE_VAR_RE = re.compile(
    r"^\s*(?:\.(?:visible|extern|weak)\s+)*\.(?:shared|global|const)\b[^;\n]*?([A-Za-z_$][\w$]*)\s*"
    r"(?:\[[^\]]*\])?\s*(?:=[^;]*)?;",
    flags=re.MULTILINE,
)


def module_scope_dependencies(ptx_outside_entry: str, body: str) -> list[str]:
    """Names of module-scope PTX the entry BODY needs but an inline-asm copy of the body cannot carry.

    Covers .shared / .global / .const variables declared outside the entry (except
    __crisp_dynamic_smem, which ptx_entry_to_inline_asm maps to an operand) and any `call` -- a
    .func the body calls is not copied either.  Returned as human-readable entries, empty when the
    body is self-contained.
    """
    lost = []
    for name in sorted({mm.group(1) for mm in _MODULE_VAR_RE.finditer(ptx_outside_entry)}):
        if name != "__crisp_dynamic_smem" and re.search(rf"(?<![\w$]){re.escape(name)}(?![\w$])", body):
            lost.append(name)
    for callee in sorted(set(re.findall(r"^\s*call(?:\.uni)?\b[^;]*?\b([A-Za-z_$][\w$]*)\s*,\s*\(", body,
                                        flags=re.MULTILINE))):
        lost.append(f"call {callee}")
    return lost


def ptx_entry_to_inline_asm(
    ptx_text: str,
    entry_name: str,
    param_c_exprs: dict[int, tuple[str, str]],
    smem_ptr_expr: str = "smem_ptr",
) -> tuple[str, str]:
    """
    Extracts `.visible .entry <entry_name>(...) { BODY }` from PTX and converts it into
    a CUDA C++ `asm volatile(...)` statement.

    Args:
        ptx_text: Full raw PTX assembly string emitted by crisp-compile.
        entry_name: Name of the kernel entry function.
        param_c_exprs: Mapping from parameter index (0..N-1) to (asm_constraint, c_expression),
            e.g. {0: ("l", "in_ptr"), 1: ("l", "bytes")}.
        smem_ptr_expr: C++ expression to pass if kernel references `__crisp_dynamic_smem`.

    Returns:
        tuple[str, str]: (inline_asm_statement, launch_bounds_annotation)
    """
    m = re.search(
        rf"\.visible \.entry\s+{re.escape(entry_name)}\s*\((.*?)\)\s*(?://[^\n]*)?\n\{{(.*?)\n\}}",
        ptx_text,
        flags=re.DOTALL,
    )
    if not m:
        raise ValueError(f"Could not find .visible .entry {entry_name} in PTX")

    body = m.group(2)
    lost = module_scope_dependencies(ptx_text[: m.start()] + ptx_text[m.end():], body)
    if lost:
        raise ValueError(
            f"{entry_name}: the inline-asm packaging copies only the entry body, but it references "
            f"module-scope PTX that would be silently dropped: {', '.join(lost)}.  "
            "A __crisp_wgu_N slot comes from to-workgroup-uniform (it broadcasts through static shared "
            "memory since endeavour 194).  NVPTX normally demotes the slot into the kernel, which packages "
            "fine; it stays module-scope when more than one function uses it -- assert the value with "
            "(declare (uniform x)) instead.  A call means a helper was not inlined."
        )

    # Identify param indices actually loaded in the entry body
    used_indices = sorted(
        {
            int(idx_str)
            for idx_str in re.findall(rf"\b{re.escape(entry_name)}_param_(\d+)\b", body)
        }
    )
    idx_to_asm_slot = {param_idx: slot for slot, param_idx in enumerate(used_indices)}

    # Prefix virtual registers to prevent NVCC parameter register shadowing (BUG-001)
    prefixed_body = prefix_ptx_registers(body)
    escaped_body = prefixed_body.replace("%", "%%")

    has_smem = "__crisp_dynamic_smem" in body

    # Replace parameter loads with register moves from inline asm inputs
    def replace_ld_param(match: re.Match) -> str:
        ld_type = match.group(1)  # e.g., b64, u64, b32, f32
        reg = match.group(2)
        param_idx = int(match.group(3))
        slot = idx_to_asm_slot[param_idx]
        mov_type = "b64" if "64" in ld_type else ("f32" if "f32" in ld_type else "b32")
        return f"mov.{mov_type} \t{reg}, %{slot};"

    escaped_body = re.sub(
        rf"ld\.param\.(\w+)\s+(%%cr_\w+),\s*\[{re.escape(entry_name)}_param_(\d+)\];",
        replace_ld_param,
        escaped_body,
    )

    if has_smem:
        smem_slot = len(used_indices)
        escaped_body = re.sub(r"\b__crisp_dynamic_smem\b", f"%{smem_slot}", escaped_body)

    # Replace ret with jump to end of inline asm block
    escaped_body = re.sub(r"\bret;", "bra.uni $L__crisp_inline_exit;", escaped_body)

    asm_lines = ["    asm volatile(\n        \"{\\n\""]
    for line in escaped_body.splitlines():
        stripped = line.rstrip()
        if not stripped:
            continue
        safe_line = stripped.replace("\\", "\\\\").replace('"', '\\"')
        asm_lines.append(f'        "{safe_line}\\n"')
    asm_lines.append('        "$L__crisp_inline_exit:\\n"')
    asm_lines.append('        "}\\n"')

    operand_strs = []
    for param_idx in used_indices:
        constraint, c_expr = param_c_exprs[param_idx]
        operand_strs.append(f'"{constraint}"({c_expr})')

    if has_smem:
        operand_strs.append(f'"l"({smem_ptr_expr})')

    asm_lines.append("        : : " + ", ".join(operand_strs))
    asm_lines.append('        : "memory"\n    );')

    m_bounds = re.search(r"\.(?:reqntid|maxntid)\s+(\d+)", ptx_text)
    bsize = m_bounds.group(1) if m_bounds else "256"
    launch_bounds = f"__launch_bounds__({bsize})"

    return "\n".join(asm_lines), launch_bounds

