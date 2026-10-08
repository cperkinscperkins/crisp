"""
Reading a .metacrisp, and turning one kernel's ABI into an ARGUMENT PLAN for a generic fixture.

Why a plan rather than a fixture per kernel: the MMA work showed that bending generated host code
to every benchmark's needs was unpredictable, and that a per-kernel apparatus cannot attribute a
difference to the kernel.  The fixture (benchmarks/reduction/fixture/reduce_fixture_l0.cpp) is
written once and knows nothing about any kernel.  Everything kernel-specific -- which physical
argument slot holds what, how big each buffer is, what it must contain before each launch --
is decided HERE, from what the compiler recorded, and written as a flat text plan.

The ABI comes from the TYPE of each parameter, not from the :physical-signature labels: a
rank-R tensor flattens to (ptr, byte_size, offset*R, stride*R, extent*R, length) and a cell to
(ptr, byte_size, offset).  (The :physical-signature labels for implicit cells read
(ULONG VOIDP ULONG) where the runtime binds (ptr, byte_size, offset); the VERIFY-AUTODIFF runner
binds by type and passes, so this module does too.)

Plan format: one directive per line, whitespace-separated, `key=value` tokens after the first
word.  See write_plan() and the fixture's header for the full contract.
"""

from __future__ import annotations

import re
import struct
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Union


# --------------------------------------------------------------------------------------------
# S-expression reading
# --------------------------------------------------------------------------------------------

class Sym(str):
    """A Lisp symbol, upcased.  Keywords keep their leading colon (':LOCAL-SIZE')."""


_TOKEN = re.compile(r'''\s*(?:
      (?P<comment>;[^\n]*)
    | (?P<open>\()
    | (?P<close>\))
    | (?P<path>\#P"(?:[^"\\]|\\.)*")
    | (?P<string>"(?:[^"\\]|\\.)*")
    | (?P<quote>\#'|')
    | (?P<atom>[^\s()";]+)
)''', re.VERBOSE)


def _atom(text: str) -> Any:
    try:
        return int(text)
    except ValueError:
        pass
    try:
        # Lisp exponent markers d/f/s/l -> e
        return float(re.sub(r'(?<=[0-9.])[dDfFsSlL](?=[+-]?[0-9])', 'e', text))
    except ValueError:
        pass
    up = text.upper()
    if up == 'NIL':
        return None
    if up == 'T':
        return True
    return Sym(up)


def read_all(text: str) -> List[Any]:
    """Every top-level form in TEXT, as nested Python lists / ints / floats / str / Sym."""
    pos, n = 0, len(text)
    stack: List[List[Any]] = [[]]
    pending_quote = 0
    while pos < n:
        m = _TOKEN.match(text, pos)
        if not m or m.end() == pos:
            if text[pos:].strip() == '':
                break
            raise ValueError(f"metacrisp: cannot read at offset {pos}: {text[pos:pos + 40]!r}")
        pos = m.end()
        kind = m.lastgroup
        if kind == 'comment':
            continue
        if kind == 'open':
            stack.append([])
            continue
        if kind == 'quote':
            pending_quote += 1          # #'f and 'x read as the bare form; nothing here needs QUOTE
            continue
        if kind == 'close':
            if len(stack) == 1:
                raise ValueError("metacrisp: unbalanced ')'")
            done = stack.pop()
            stack[-1].append(done)
            continue
        if kind == 'path':
            stack[-1].append(m.group('path')[3:-1])
        elif kind == 'string':
            stack[-1].append(m.group('string')[1:-1].replace('\\"', '"'))
        else:
            stack[-1].append(_atom(m.group('atom')))
    if len(stack) != 1:
        raise ValueError("metacrisp: unbalanced '('")
    return stack[0]


def plist(lst: List[Any]) -> Dict[str, Any]:
    """A property list -> dict keyed by the keyword name without its colon, upcased."""
    out = {}
    for i in range(0, len(lst) - 1, 2):
        k = lst[i]
        if isinstance(k, Sym) and k.startswith(':'):
            out[k[1:]] = lst[i + 1]
    return out


# --------------------------------------------------------------------------------------------
# Types
# --------------------------------------------------------------------------------------------

ELEM_BYTES = {
    'FLOAT': 4, 'DOUBLE': 8, 'HALF': 2, 'BFLOAT16': 2,
    'INT': 4, 'UINT': 4, 'LONG': 8, 'ULONG': 8, 'SHORT': 2, 'USHORT': 2, 'CHAR': 1, 'UCHAR': 1,
}
ELEM_CODE = {   # the fixture's element codes
    'FLOAT': 'f32', 'DOUBLE': 'f64', 'HALF': 'f16', 'BFLOAT16': 'bf16',
    'INT': 'i32', 'UINT': 'u32', 'LONG': 'i64', 'ULONG': 'u64', 'SHORT': 'i16', 'USHORT': 'u16',
    'CHAR': 'i8', 'UCHAR': 'u8',
}


@dataclass
class StorageType:
    kind: str            # 'cell' | 'tensor'
    elem: str            # upcased Crisp element type, e.g. 'FLOAT'
    rank: int            # 0 for a cell
    address_space: str   # 'GLOBAL' | 'LOCAL' | 'CONSTANT'

    @property
    def elem_bytes(self) -> int:
        return ELEM_BYTES[self.elem]

    @property
    def width(self) -> int:
        """Physical argument slots this type occupies."""
        return 3 if self.kind == 'cell' else 2 + 3 * self.rank + 1


def _addr(form: List[Any], default: str = 'GLOBAL') -> str:
    for i, x in enumerate(form):
        if x == ':ADDRESS-SPACE' and i + 1 < len(form):
            return str(form[i + 1]).lstrip(':')
    return default


def parse_storage_type(form: Any, aliases: Dict[str, Any]) -> Optional[StorageType]:
    """A storage-handle type form (or an alias naming one) -> StorageType; None for scalars."""
    seen = 0
    while isinstance(form, Sym) and form in aliases and seen < 16:
        form, seen = aliases[form], seen + 1
    if not isinstance(form, list) or not form:
        return None
    head = str(form[0])
    if head == 'CELL':
        # (cell T :address-space AS) from an alias, or the canonical (cell T :AS)
        a = _addr(form, default='')
        if not a and len(form) >= 3 and isinstance(form[2], Sym) and form[2].startswith(':'):
            a = form[2][1:]
        return StorageType('cell', str(form[1]), 0, a or 'GLOBAL')
    if head == 'VECTOR':
        return StorageType('tensor', str(form[1]), 1, _addr(form))
    if head == 'MATRIX':
        return StorageType('tensor', str(form[1]), 2, _addr(form))
    if head == 'TENSOR':
        # alias form (tensor T N :address-space AS ..) or canonical (tensor T N :AS :align :layout)
        rank = int(form[2])
        a = _addr(form, default='')
        if not a and len(form) >= 4 and isinstance(form[3], Sym) and form[3].startswith(':'):
            a = form[3][1:]
        return StorageType('tensor', str(form[1]), rank, a or 'GLOBAL')
    return None


# --------------------------------------------------------------------------------------------
# The kernel record
# --------------------------------------------------------------------------------------------

@dataclass
class Param:
    name: str
    stype: Optional[StorageType]
    scalar_type: Optional[str]
    first_slot: int
    last_slot: int
    implicit: bool
    direction: str = 'in'                     # 'in' | 'out' (declared params)
    size_expr: Any = None                     # implicit scratch
    launch_init: Optional[Dict[str, Any]] = None


@dataclass
class KernelRecord:
    name: str
    local_size: List[int]
    simd_width: Optional[int]
    params: List[Param] = field(default_factory=list)
    strategy: Optional[str] = None            # :global-size :strategy, e.g. 'STRIDED'
    occupancy: Optional[float] = None         # :global-size :occupancy as DECLARED (None = undeclared)
    compute_units: Optional[int] = None       # the hardware profile's :compute-units
    raw: Dict[str, Any] = field(default_factory=dict)

    @property
    def n_slots(self) -> int:
        return 1 + max(p.last_slot for p in self.params) if self.params else 0


def read_metacrisp(path: Path) -> List[KernelRecord]:
    forms = read_all(Path(path).read_text(encoding='utf-8', errors='replace'))
    sections = {str(f[0]): f[1:] for f in forms if isinstance(f, list) and f and isinstance(f[0], Sym)}
    aliases: Dict[str, Any] = {}
    for d in sections.get(':ALIASES', []):
        if isinstance(d, list) and len(d) >= 3 and d[0] == 'DEF-TYPE':
            aliases[str(d[1])] = d[2]
    simd = None
    compute_units = None
    hp = sections.get(':HARDWARE-PROFILE')
    if hp and isinstance(hp[0], list):
        simd = plist(hp[0]).get('SIMD-WIDTH')
        compute_units = plist(hp[0]).get('COMPUTE-UNITS')

    kernels = []
    for k in sections.get(':KERNELS', []):
        kp = plist(k)
        local = [1, 1, 1]
        ls = kp.get('LOCAL-SIZE')
        if isinstance(ls, list):
            nums = _ints_in(ls)
            if nums:
                local = (nums + [1, 1])[:3]
        rec = KernelRecord(name=str(kp['NAME']), local_size=local, simd_width=simd, raw=kp,
                           compute_units=compute_units if isinstance(compute_units, int) else None)
        gsz = kp.get('GLOBAL-SIZE')
        if isinstance(gsz, list):
            g = plist(gsz[1:])
            rec.strategy = str(g['STRATEGY']).lstrip(':') if g.get('STRATEGY') else None
            occ = g.get('OCCUPANCY')
            rec.occupancy = float(occ) if isinstance(occ, (int, float)) and not isinstance(occ, bool) else None
        for e in kp.get('IMPLICIT-PARAMS') or []:
            ep = plist(e)
            st = parse_storage_type(ep.get('TYPE'), aliases)
            lo, hi = ep['RANGE']
            rec.params.append(Param(name=ep['NAME'], stype=st, scalar_type=None, first_slot=lo,
                                    last_slot=hi, implicit=True, size_expr=ep.get('SIZE-EXPR')))
        for e in kp.get('DECLARED-SIGNATURE') or []:
            ep = plist(e)
            st = parse_storage_type(ep.get('TYPE'), aliases)
            lo, hi = ep['RANGE']
            li = ep.get('LAUNCH-INIT')
            rec.params.append(Param(name=ep['NAME'], stype=st,
                                    scalar_type=None if st else str(ep.get('TYPE')).upper(),
                                    first_slot=lo, last_slot=hi, implicit=False,
                                    direction=str(ep.get('DIRECTION', ':IN')).lstrip(':').lower(),
                                    launch_init=plist(li) if isinstance(li, list) else None))
        rec.params.sort(key=lambda p: p.first_slot)
        for p in rec.params:
            if p.stype and p.last_slot - p.first_slot + 1 != p.stype.width:
                raise ValueError(f"{rec.name}: parameter {p.name} spans slots {p.first_slot}-{p.last_slot} "
                                 f"but its type {p.stype} flattens to {p.stype.width}")
        kernels.append(rec)
    return kernels


def _ints_in(x: Any) -> List[int]:
    if isinstance(x, bool):
        return []
    if isinstance(x, int):
        return [x]
    if isinstance(x, list):
        out: List[int] = []
        for y in x:
            out.extend(_ints_in(y))
        return out
    return []


# --------------------------------------------------------------------------------------------
# The argument plan
# --------------------------------------------------------------------------------------------

def scalar_bytes_hex(value: Any, elem: str) -> str:
    """VALUE encoded as ELEM's little-endian bytes, hex.  Keywords :INFINITY / :-INFINITY allowed."""
    if value in (Sym(':INFINITY'), ':INFINITY'):
        value = float('inf')
    elif value in (Sym(':-INFINITY'), ':-INFINITY'):
        value = float('-inf')
    fmt = {'FLOAT': '<f', 'DOUBLE': '<d', 'INT': '<i', 'UINT': '<I', 'LONG': '<q', 'ULONG': '<Q',
           'SHORT': '<h', 'USHORT': '<H', 'CHAR': '<b', 'UCHAR': '<B'}.get(elem)
    if fmt is None:
        raise ValueError(f"no scalar encoding for element type {elem}")
    if fmt[-1] in 'fd':
        return struct.pack(fmt, float(value)).hex()
    return struct.pack(fmt, int(value)).hex()


POISON = {   # what an un-written output looks like: NaN for floats, all-ones for integers
    'FLOAT': '0000c07f', 'DOUBLE': '000000000000f87f', 'HALF': '007e', 'BFLOAT16': 'c07f',
}


def poison_hex(elem: str) -> str:
    return POISON.get(elem, 'ff' * ELEM_BYTES[elem])


GROUPS_TOKEN = '@groups'      # a size the fixture resolves once it has computed the grid (181)


@dataclass
class Buffer:
    bid: int
    name: str
    elem: str
    count: Union[int, str]    # an int, or GROUPS_TOKEN: one per work-group, resolved by the fixture
    init: str                 # 'gen' | 'once-zero' | 'each-fill' | 'each-poison'
    fill_hex: str = ''
    readback: bool = False
    role: str = ''            # 'input' | 'output' | 'scratch'


def build_plan(rec: KernelRecord, n_elements: int, groups: int,
               generator: str = 'hash', gen_shift: int = 29) -> Dict[str, Any]:
    """The argument plan for one launch configuration of REC.

    Inputs (declared, direction in, rank >= 1) get N_ELEMENTS generated elements each.
    Outputs get, before EVERY launch, either the identity their :launch-init names, or POISON:
    a last-man output is overwritten, so a poisoned value surviving a launch means the kernel
    never wrote it (the stale-state failure endeavour 179 fixed).  Implicit global scratch is
    zeroed ONCE, the kernel's documented precondition.  Implicit local scratch is sized from its
    :size-expr against the local size and the profile's warp width.  Scratch sized
    :match-num-workgroups (a last-man kernel's partials, endeavour 181) is SYMBOLIC -- `@groups` --
    because under occupancy the group count is computed inside the fixture.
    """
    wg = rec.local_size[0] * rec.local_size[1] * rec.local_size[2]
    warp = rec.simd_width or 32          # %l0-scratch-warp-size: profile :simd-width, else 32
    buffers: List[Buffer] = []
    slots: List[str] = [''] * rec.n_slots

    def scratch_count(p: Param) -> int:
        se = p.size_expr
        if p.stype.kind == 'cell':
            return 1
        if isinstance(se, int):
            return se
        name = str(se or '').lstrip(':').upper()
        if name == 'MATCH-WORKGROUP-SIZE':
            return wg
        if name == 'MATCH-NUM-WARPS-PER-WORKGROUP':
            return (wg + warp - 1) // warp      # CEILING, as the hoister does
        if name == 'MATCH-NUM-WORKGROUPS':
            return GROUPS_TOKEN                 # one per work-group; the fixture knows how many
        raise ValueError(f"{rec.name}: cannot size scratch {p.name} with :size-expr {se!r}")

    def descriptor(base: int, st: StorageType, count: int, first_value: str):
        """Fill the slots of a cell/tensor at BASE.  Rank > 1 is laid out row-major compact."""
        slots[base] = first_value
        nbytes = f"{count}*{st.elem_bytes}" if count == GROUPS_TOKEN else count * st.elem_bytes
        slots[base + 1] = f"u64 {nbytes}"
        if st.kind == 'cell':
            slots[base + 2] = "u64 0"
            return
        r = st.rank
        if r != 1:
            raise ValueError(f"{rec.name}: rank-{r} tensors are not planned yet (only rank 1)")
        slots[base + 2] = "u64 0"            # offset
        slots[base + 3] = "u64 1"            # stride
        slots[base + 4] = f"u64 {count}"     # extent
        slots[base + 5] = f"u64 {count}"     # length

    for p in rec.params:
        st = p.stype
        if st is None:
            raise ValueError(f"{rec.name}: scalar parameter {p.name} ({p.scalar_type}) -- the plan "
                             f"has no value for it yet")
        if p.implicit:
            count = scratch_count(p)
            if st.address_space == 'LOCAL':
                descriptor(p.first_slot, st, count, f"slm {count * st.elem_bytes}")
                continue
            b = Buffer(len(buffers), p.name, st.elem, count, 'once-zero', role='scratch')
            buffers.append(b)
            descriptor(p.first_slot, st, count, f"ptr {b.bid}")
            continue
        if p.direction == 'in':
            count = 1 if st.kind == 'cell' else n_elements
            b = Buffer(len(buffers), p.name, st.elem, count, 'gen', role='input')
        else:
            count = 1 if st.kind == 'cell' else _output_count(rec, p)
            if p.launch_init and 'IDENTITY' in p.launch_init:
                b = Buffer(len(buffers), p.name, st.elem, count, 'each-fill',
                           fill_hex=scalar_bytes_hex(p.launch_init['IDENTITY'], st.elem),
                           readback=True, role='output')
            elif p.launch_init:
                raise ValueError(f"{rec.name}: output {p.name} needs {p.launch_init} before each launch, "
                                 f"which the plan cannot produce (not a constant)")
            else:
                b = Buffer(len(buffers), p.name, st.elem, count, 'each-poison',
                           fill_hex=poison_hex(st.elem), readback=True, role='output')
        buffers.append(b)
        descriptor(p.first_slot, st, count, f"ptr {b.bid}")

    missing = [i for i, s in enumerate(slots) if not s]
    if missing:
        raise ValueError(f"{rec.name}: physical slots {missing} are not covered by any parameter")
    return {'kernel': rec.name, 'local': rec.local_size, 'groups': groups, 'generator': generator,
            'gen_shift': gen_shift, 'buffers': buffers, 'slots': slots, 'n_elements': n_elements}


def _output_count(rec: KernelRecord, p: Param) -> int:
    """A reduction writes its result to element 0 of an output vector, so one element is enough.
    Outputs with more elements (e.g. a per-workgroup partials vector) are a later extension."""
    if p.stype.rank != 1:
        raise ValueError(f"{rec.name}: output {p.name} is rank {p.stype.rank}; only cells and "
                         f"rank-1 outputs are planned")
    return 1


def write_plan(plan: Dict[str, Any], spv: Path, out: Path, warmup: int, iters: int,  # spv: the module (.spv or .ptx)
               build_flags: str = '') -> Path:
    lines = [
        "# argument plan -- written by scripts/crisp_bench/metacrisp.py; read by reduce_fixture_l0.cpp",
        f"module {spv}",
        f"kernel {plan['kernel']}",
        "local {} {} {}".format(*plan['local']),
        f"groups {plan['groups']}",
        f"warmup {warmup}",
        f"iters {iters}",
        f"generator {plan['generator']} shift={plan['gen_shift']}",
    ]
    if build_flags:
        lines.append(f"buildflags {build_flags}")
    for b in plan['buffers']:
        tok = [f"buffer {b.bid}", f"name={b.name}", f"elem={ELEM_CODE[b.elem]}", f"count={b.count}",
               f"init={b.init}"]
        if b.fill_hex:
            tok.append(f"fill={b.fill_hex}")
        if b.readback:
            tok.append("readback=1")
        lines.append(' '.join(tok))
    for i, s in enumerate(plan['slots']):
        lines.append(f"slot {i} {s}")
    out.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    return out
