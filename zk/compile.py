#!/usr/bin/env python3
"""Flattened TapeOut netlist -> Circom "eval" circuit.

Statement: "for packed input X, the circuit outputs packed Y".
  public:  X = sum x[i] * 2^i   (one field element per <=248-bit chunk)
           Y = sum y[i] * 2^i
  private: x[i] bits (boolean-constrained), gate wires
  gates:   g = 1 - a*b  (one constraint per NAND)
Deterministic: same netlist -> same .circom -> same r1cs / wasm (the Groth16 zkey adds the ceremony, zk/ceremony/).
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "circuits"))
from netlist import Nand, Netlist  # noqa: E402

CHUNK = 248  # bits per public field element (< 254-bit BN254 field)


def _chunks(n: int):
    return [(i, min(i + CHUNK, n)) for i in range(0, n, CHUNK)]


def to_circom(nl: Netlist, template: str = "TapeOutEval") -> str:
    if any(not isinstance(e, Nand) for e in nl.elements):
        raise ValueError("flatten (and ideally fold) the netlist first")
    n_in, n_gates = nl.n_in, len(nl.elements)

    def ref(s):
        if s == 0:
            return "0"
        if s == 1:
            return "1"
        if s < 2 + n_in:
            return f"x[{s - 2}]"
        return f"g[{s - 2 - n_in}]"

    xc, yc = _chunks(n_in), _chunks(nl.n_out)
    L = ["pragma circom 2.1.6;", "", f"template {template}() {{",
         f"    signal input X[{len(xc)}];", f"    signal input Y[{len(yc)}];",
         f"    signal input x[{n_in}];", f"    signal g[{n_gates}];", ""]
    for i in range(n_in):
        L.append(f"    x[{i}] * (x[{i}] - 1) === 0;")
    for ci, (a, b) in enumerate(xc):
        L.append(f"    X[{ci}] === " + " + ".join(f"x[{i}] * {1 << (i - a)}" for i in range(a, b)) + ";")
    for k, e in enumerate(nl.elements):
        L.append(f"    g[{k}] <== 1 - {ref(e.a)} * {ref(e.b)};")
    first_out = 2 + n_in + n_gates - nl.n_out
    for ci, (a, b) in enumerate(yc):
        L.append(f"    Y[{ci}] === " + " + ".join(f"{ref(first_out + i)} * {1 << (i - a)}" for i in range(a, b)) + ";")
    L += ["}", "", f"component main {{public [X, Y]}} = {template}();", ""]
    return "\n".join(L)


def public_signals(bits_in, bits_out):
    def pack(bits):
        return [str(sum(int(bits[i]) << (i - a) for i in range(a, b))) for a, b in _chunks(len(bits))]
    return pack(bits_in), pack(bits_out)


def circom_input(bits_in, bits_out) -> dict:
    X, Y = public_signals(bits_in, bits_out)
    return {"X": X, "Y": Y, "x": [str(int(b)) for b in bits_in]}
