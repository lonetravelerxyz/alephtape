"""TapeOut netlist toolkit: encode / decode / BLIF import / simulate (with REF) / flatten.

Format: flat element stream, u24 big-endian signal indices.
Signals: 0 = const0, 1 = const1, 2..1+nIn = inputs, then one new signal per NAND/LATCH, nOut per REF.
  0x00 a b                                   NAND
  0x01 d                                     LATCH (combinational code here rejects it)
  0x02 cpu:20B circuitId:u64 nIn:u8 nOut:u8 ins:u24*nIn   REF (sub-circuit)
Outputs are the LAST nOut signals. I/O bits are little-endian packed (bit i = byte[i>>3] >> (i&7)).
"""
from __future__ import annotations

import itertools
import sys
from dataclasses import dataclass
from typing import Callable, Sequence

NAND, LATCH, REF = 0, 1, 2
MAX_U24 = 0xFFFFFF


@dataclass(frozen=True)
class Nand:
    a: int
    b: int


@dataclass(frozen=True)
class Ref:
    cpu: str          # 0x-prefixed address (case-insensitive)
    circuit_id: int
    ins: tuple        # signal indices
    n_out: int


@dataclass
class Netlist:
    n_in: int
    n_out: int
    elements: list

    @property
    def n_signals(self) -> int:
        return 2 + self.n_in + sum(e.n_out if isinstance(e, Ref) else 1 for e in self.elements)

    @property
    def nand_count(self) -> int:  # == NAND transistors burned by tapeout (REF burns nothing)
        return sum(1 for e in self.elements if isinstance(e, Nand))


# ---------------------------------------------------------------- encode / decode
def _u24(v: int) -> bytes:
    if not 0 <= v <= MAX_U24:
        raise ValueError(f"u24 out of range: {v}")
    return v.to_bytes(3, "big")


def encode(nl: Netlist) -> bytes:
    out = bytearray()
    for e in nl.elements:
        if isinstance(e, Nand):
            out += bytes([NAND]) + _u24(e.a) + _u24(e.b)
        elif isinstance(e, Ref):
            if len(e.ins) > 255 or e.n_out > 255:
                raise ValueError("REF pins exceed u8")
            out += bytes([REF]) + bytes.fromhex(e.cpu[2:].lower().rjust(40, "0"))
            out += e.circuit_id.to_bytes(8, "big") + bytes([len(e.ins), e.n_out])
            for s in e.ins:
                out += _u24(s)
        else:
            raise TypeError(e)
    return bytes(out)


def decode(data: bytes, n_in: int, n_out: int) -> Netlist:
    p, els = 0, []
    while p < len(data):
        op = data[p]; p += 1
        if op == NAND:
            els.append(Nand(int.from_bytes(data[p:p + 3], "big"), int.from_bytes(data[p + 3:p + 6], "big"))); p += 6
        elif op == REF:
            cpu = "0x" + data[p:p + 20].hex(); p += 20
            cid = int.from_bytes(data[p:p + 8], "big"); p += 8
            ni, no = data[p], data[p + 1]; p += 2
            ins = tuple(int.from_bytes(data[p + 3 * i:p + 3 * i + 3], "big") for i in range(ni)); p += 3 * ni
            els.append(Ref(cpu, cid, ins, no))
        elif op == LATCH:
            raise ValueError("LATCH not supported in combinational toolkit")
        else:
            raise ValueError(f"bad opcode {op} at {p - 1}")
    return Netlist(n_in, n_out, els)


# ---------------------------------------------------------------- bits
def pack_bits(bits: Sequence[int]) -> bytes:
    b = bytearray((len(bits) + 7) // 8)
    for i, v in enumerate(bits):
        if v:
            b[i >> 3] |= 1 << (i & 7)
    return bytes(b)


def unpack_bits(data: bytes, n: int) -> list:
    return [(data[i >> 3] >> (i & 7)) & 1 for i in range(n)]


# ---------------------------------------------------------------- simulate
Resolver = Callable[[str, int], Netlist]  # (cpu, circuitId) -> Netlist


def simulate(nl: Netlist, inputs: Sequence[int], resolve: Resolver | None = None) -> list:
    if len(inputs) != nl.n_in:
        raise ValueError(f"expected {nl.n_in} inputs, got {len(inputs)}")
    sig = [0, 1] + [int(v) & 1 for v in inputs]
    for e in nl.elements:
        if isinstance(e, Nand):
            sig.append(0 if (sig[e.a] and sig[e.b]) else 1)
        else:
            if resolve is None:
                raise ValueError("REF element needs a resolver")
            sub = resolve(e.cpu.lower(), e.circuit_id)
            if sub.n_in != len(e.ins) or sub.n_out != e.n_out:
                raise ValueError(f"REF pin mismatch for {e.cpu}#{e.circuit_id}")
            sig += simulate(sub, [sig[s] for s in e.ins], resolve)
    if nl.n_out > len(sig) - 2 - nl.n_in:
        raise ValueError("too few signals for outputs")
    return sig[-nl.n_out:]


# ---------------------------------------------------------------- flatten (REF -> NAND only)
def flatten(nl: Netlist, resolve: Resolver) -> Netlist:
    """Inline every REF recursively. Deterministic; outputs stay the last n_out signals."""
    out_els: list = []
    nxt = [2 + nl.n_in]

    def inline(sub: Netlist, in_sigs: list) -> list:
        local = [0, 1] + list(in_sigs)  # local signal index -> global signal index
        for e in sub.elements:
            if isinstance(e, Nand):
                out_els.append(Nand(local[e.a], local[e.b])); local.append(nxt[0]); nxt[0] += 1
            else:
                local += inline(resolve(e.cpu.lower(), e.circuit_id), [local[s] for s in e.ins])
        return local[-sub.n_out:]

    outs = inline(nl, list(range(2, 2 + nl.n_in)))
    tail = list(range(nxt[0] - nl.n_out, nxt[0]))
    if outs != tail:  # buffer outputs so they are the final signals
        inv = []
        for s in outs:
            out_els.append(Nand(s, s)); inv.append(nxt[0]); nxt[0] += 1
        for s in inv:
            out_els.append(Nand(s, s)); nxt[0] += 1
    return Netlist(nl.n_in, nl.n_out, out_els)


# ---------------------------------------------------------------- constant folding (NAND-only)
def fold(nl: Netlist) -> Netlist:
    """Function-preserving simplification of a flattened NAND netlist.

    Tracks every signal as a literal (base, inverted) or a constant, so constant weights wired
    through REF collapse: NAND(0,x)=1, NAND(1,x)=~x, NAND(x,x)=~x, NAND(x,~x)=1, ~~x=x.
    Deterministic, so anyone can re-derive the folded circuit from the on-chain netlists.
    """
    if any(not isinstance(e, Nand) for e in nl.elements):
        raise ValueError("fold() expects a flattened (NAND-only) netlist")
    CONST0, CONST1 = ("c", 0), ("c", 1)
    lit = {0: CONST0, 1: CONST1}
    for i in range(nl.n_in):
        lit[2 + i] = ("s", 2 + i, False)  # (kind, base new-signal, inverted)
    out_els: list = []
    nxt = [2 + nl.n_in]
    inv_cache: dict = {}

    def emit(a, b):
        out_els.append(Nand(a, b)); s = nxt[0]; nxt[0] += 1; return s

    def materialize(L):
        if L[0] == "c":
            return L[1]
        _, base, inv = L
        if not inv:
            return base
        if base not in inv_cache:
            inv_cache[base] = emit(base, base)
        return inv_cache[base]

    def neg(L):
        return ("c", 1 - L[1]) if L[0] == "c" else ("s", L[1], not L[2])

    sig = 2 + nl.n_in
    for e in nl.elements:
        A, B = lit[e.a], lit[e.b]
        if A == CONST0 or B == CONST0:
            r = CONST1
        elif A == CONST1:
            r = neg(B)
        elif B == CONST1:
            r = neg(A)
        elif A == B:
            r = neg(A)
        elif A[1] == B[1]:  # x NAND ~x
            r = CONST1
        else:
            r = ("s", emit(materialize(A), materialize(B)), False)
        lit[sig] = r
        sig += 1

    outs = [lit[s] for s in range(sig - nl.n_out, sig)]
    # outputs must be the last n_out signals: invert all, then invert again (2 gates per output)
    ts = [emit(m, m) for m in (materialize(L) for L in outs)]
    for t in ts:
        emit(t, t)
    return Netlist(nl.n_in, nl.n_out, out_els)


# ---------------------------------------------------------------- BLIF (yosys `abc -g NAND`) import
def _parse_blif(path):
    lines = open(path).read().replace("\\\n", " ").split("\n")
    ins, outs, names, cur = [], [], [], None
    for line in lines:
        line = line.split("#")[0].strip()
        if not line:
            continue
        if line.startswith(".inputs"):
            ins += line.split()[1:]
        elif line.startswith(".outputs"):
            outs += line.split()[1:]
        elif line.startswith(".names"):
            f = line.split()[1:]; cur = (f[:-1], f[-1], []); names.append(cur)
        elif line.startswith("."):
            cur = None
        elif cur is not None:
            cur[2].append(line.split())
    return ins, outs, names


def _truth(nin, rows):
    tt = []
    for bits in itertools.product([0, 1], repeat=nin):
        v = 0
        for r in rows:
            pat, o = (r[0], r[1]) if nin else ("", r[0])
            if all(p == "-" or int(p) == b for p, b in zip(pat, bits)):
                v = int(o)
        tt.append(v)
    return tuple(tt)


def from_blif(path: str):
    """Returns (Netlist, input_names, output_names). Input names look like 'x[3]'."""
    ins, outs, names = _parse_blif(path)
    drv = {fo: (fi, _truth(len(fi), rows)) for fi, fo, rows in names}
    sig = {n: 2 + i for i, n in enumerate(ins)}
    els: list = []
    nxt = [2 + len(ins)]

    def emit(a, b):
        els.append(Nand(a, b)); s = nxt[0]; nxt[0] += 1; return s

    sys.setrecursionlimit(1_000_000)

    def get(n):
        if n in sig:
            return sig[n]
        fi, tt = drv[n]
        if len(fi) == 0:
            s = 1 if tt == (1,) else 0
        elif len(fi) == 1 and tt == (1, 0):
            a = get(fi[0]); s = emit(a, a)
        elif len(fi) == 1 and tt == (0, 1):
            s = get(fi[0])
        elif len(fi) == 2 and tt == (1, 1, 1, 0):
            a, b = get(fi[0]), get(fi[1]); s = emit(a, b)
        else:
            raise ValueError(f"unsupported BLIF cell {fi} {tt}")
        sig[n] = s
        return s

    osig = [get(o) for o in outs]
    if osig != list(range(nxt[0] - len(outs), nxt[0])):
        inv = [emit(s, s) for s in osig]
        for s in inv:
            emit(s, s)
    return Netlist(len(ins), len(outs), els), ins, outs


def port_index(names: list, port: str, width: int) -> list:
    """Positions of port[0..width-1] within a BLIF input/output name list (handles 1-bit ports)."""
    if width == 1 and port in names:
        return [names.index(port)]
    return [names.index(f"{port}[{i}]") for i in range(width)]
