#!/usr/bin/env python3
"""zkgen: turn any circuit taped out on an allowed processor (ℵ₀) into a verifiable circuit.

Reads the top netlist and every REF sub-circuit from the chain (first-visit DFS, the order AlephRegistry.register
hashes), flattens and folds them (circuits/netlist.py), compiles the eval circuit (zk/compile.py, circom), picks the
smallest PSE ppot that fits, runs a Groth16 phase-2 ceremony (zk/ceremony.cjs: one CSPRNG contribution that is
discarded + a beacon from the latest finalized X Layer mainnet block), proves one sample input as a self-check and
exports what registration needs: the 24-word wrapper verifier .sol, vk.json, the `subs` list and the flatHash.

  circuits/.venv/bin/python zk/zkgen.py --rpc <url> --processor <addr> --circuit <id> --out <dir>
      [--prefix Name] [--max-power 17] [--registry <addr> --key <registryKey>] [--r1cs-only]

--r1cs-only stops after the r1cs (size check, no ceremony). --registry/--key compares the computed flatHash with the
registry's stored one (and fails on a mismatch). Python stdlib only (+ circom, node, zk/node_modules/snarkjs).
Output: <dir>/{folded.json, circuit.circom, circuit.r1cs, circuit_js/circuit.wasm, circuit.zkey, vk.json,
        <Prefix>Groth16Verifier.sol, transcript.json, sample.json, manifest.json}
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import shutil
import subprocess
import sys
import time
import urllib.request

ZK = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(ZK)
sys.path[:0] = [os.path.join(ROOT, "circuits"), ZK]
from netlist import Netlist, Ref, decode, encode, flatten, fold, pack_bits, simulate  # noqa: E402
from compile import circom_input, to_circom, _chunks  # noqa: E402
from CompactFIPS202 import Keccak  # noqa: E402  (Keccak team reference implementation, CC0)

SNARK = os.environ.get("SNARKJS") or os.path.join(ZK, "node_modules", ".bin", "snarkjs")
CIRCOM = os.environ.get("CIRCOM") or os.path.join(ZK, "bin", "circom")
PTAU_DIR = os.environ.get("PTAU_DIR") or os.path.join(ZK, "ptau")
PTAUS = {14: "ppot_0080_14.ptau", 17: "ppot_0080_17.ptau", 18: "ppot_0080_18.ptau"}  # PSE perpetual ppot 0080
NAME = "circuit"  # file base name inside a job dir: circuit.r1cs, circuit_js/circuit.wasm, circuit.zkey
SEL_NETLIST, SEL_INFO = "0x3fc4be56", "0x084d60f1"  # netlist(uint256), circuitInfo(uint256)


def keccak256(b: bytes) -> bytes:
    return bytes(Keccak(1088, 512, bytearray(b), 0x01, 32))


SEL_REG_CIRCUIT = "0x" + keccak256(b"circuit(bytes32)")[:4].hex()


def log(*a):
    print(*a, file=sys.stderr, flush=True)


# ---------------------------------------------------------------- chain reads (plain JSON-RPC)
class Chain:
    def __init__(self, rpc: str):
        self.rpc = rpc
        self.chain_id = int(self.call("eth_chainId", []), 16)

    def call(self, method, params):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
        for attempt in range(5):
            try:
                req = urllib.request.Request(self.rpc, data=body, headers={"Content-Type": "application/json", "User-Agent": "zkgen"})
                j = json.load(urllib.request.urlopen(req, timeout=60))
                if "error" in j:
                    raise RuntimeError(f"{method}: {j['error']}")
                return j["result"]
            except (OSError, urllib.error.URLError) as e:
                if attempt == 4:
                    raise SystemExit(f"rpc {method} failed: {e}")
                time.sleep(1 + attempt)

    def eth_call(self, to, data):
        return bytes.fromhex(self.call("eth_call", [{"to": to, "data": data}, "latest"])[2:])

    def netlist(self, cpu: str, cid: int) -> bytes:
        r = self.eth_call(cpu, SEL_NETLIST + cid.to_bytes(32, "big").hex())
        if len(r) < 64:
            raise SystemExit(f"{cpu}#{cid}: no netlist (not taped out?)")
        off = int.from_bytes(r[:32], "big")
        n = int.from_bytes(r[off:off + 32], "big")
        return r[off + 32:off + 32 + n]

    def info(self, cpu: str, cid: int):
        r = self.eth_call(cpu, SEL_INFO + cid.to_bytes(32, "big").hex())
        return [int.from_bytes(r[32 * i:32 * i + 32], "big") for i in range(4)]  # nIn, nOut, nState, gateCount

    def registry_circuit(self, registry: str, key: str) -> dict:
        r = self.eth_call(registry, SEL_REG_CIRCUIT + key[2:].rjust(64, "0"))
        w = [r[32 * i:32 * i + 32] for i in range(9)]
        return {"processor": "0x" + w[0][12:].hex(), "circuitId": int.from_bytes(w[1], "big"), "flatHash": "0x" + w[2].hex(),
                "nIn": int.from_bytes(w[3], "big"), "nOut": int.from_bytes(w[4], "big"), "nPub": int.from_bytes(w[5], "big"),
                "verifier": "0x" + w[7][12:].hex()}


# ---------------------------------------------------------------- netlists from the chain
def load_tree(chain: Chain, cpu: str, cid: int):
    """Top netlist + every REF sub-circuit. Returns (top, resolve, subs in first-visit DFS order, raw bytes by ref)."""
    raw, nets = {}, {}

    def get(c, i):
        k = (c.lower(), i)
        if k not in nets:
            b = chain.netlist(c, i)
            n_in, n_out, n_state, _ = chain.info(c, i)
            if n_state:
                raise SystemExit(f"{c}#{i} has {n_state} LATCHes: only combinational circuits can be made verifiable (eval)")
            raw[k], nets[k] = b, decode(b, n_in, n_out)
        return nets[k]

    top = get(cpu, cid)
    subs, seen = [], set()

    def dfs(nl: Netlist):
        for e in nl.elements:
            if isinstance(e, Ref):
                k = (e.cpu.lower(), e.circuit_id)
                if k in seen:
                    continue
                seen.add(k)
                subs.append(k)
                dfs(get(*k))

    dfs(top)
    return top, (lambda c, i: get(c, i)), subs, raw


def flat_hash(cpu, cid, subs, raw) -> str:
    """AlephRegistry.register: keccak(abi.encode(keccak(top)) ++ abi.encode(processor, id, keccak(netlist)) per sub)."""
    acc = keccak256(raw[(cpu.lower(), cid)])
    for c, i in subs:
        acc += bytes(12) + bytes.fromhex(c[2:]) + i.to_bytes(32, "big") + keccak256(raw[(c, i)])
    return "0x" + keccak256(acc).hex()


# ---------------------------------------------------------------- build
def run(label, cmd, **kw):
    t = time.time()
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode:
        raise SystemExit(f"{label} failed:\n{r.stdout[-1500:]}\n{r.stderr[-1500:]}")
    log(f"  {label:24s} {time.time() - t:7.1f}s")
    return r.stdout


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def need_power(n_constraints, n_pub):
    """snarkjs groth16 setup: ceil(log2(nConstraints + nPubInputs + nOutputs + 1)) <= ptau power."""
    return max(1, math.ceil(math.log2(n_constraints + n_pub + 1)))


def pick_ptau(power, max_power):
    for p in sorted(PTAUS):
        if p >= power and p <= max_power and os.path.exists(os.path.join(PTAU_DIR, PTAUS[p])):
            return p, os.path.join(PTAU_DIR, PTAUS[p])
    have = [p for p in sorted(PTAUS) if os.path.exists(os.path.join(PTAU_DIR, PTAUS[p]))]
    raise SystemExit(f"circuit needs a 2^{power} ptau; available here: {', '.join(f'2^{p}' for p in have) or 'none'} "
                     f"(max allowed 2^{max_power}). Too big for this zkgen.")


PROVE_JS = r"""
const snarkjs = require(process.argv[1]);
const fs = require("fs");
(async () => {
  const [wasm, zkey, vkf, inp, out] = process.argv.slice(2);
  const { proof, publicSignals } = await snarkjs.groth16.fullProve(JSON.parse(fs.readFileSync(inp)), wasm, zkey);
  if (!(await snarkjs.groth16.verify(JSON.parse(fs.readFileSync(vkf)), publicSignals, proof))) throw new Error("sample proof does not verify");
  const [a, b, c] = JSON.parse("[" + (await snarkjs.groth16.exportSolidityCallData(proof, publicSignals)) + "]");
  const words = [a[0], a[1], b[0][0], b[0][1], b[1][0], b[1][1], c[0], c[1]].concat(Array(16).fill("0x" + "0".repeat(64)));
  fs.writeFileSync(out, JSON.stringify({ proof: words, pub: publicSignals }));
  process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });
"""


def main(argv=None):
    ap = argparse.ArgumentParser(description="TapeOut circuit on chain -> Groth16 verifier + registry args")
    ap.add_argument("--rpc", required=True)
    ap.add_argument("--processor", required=True)
    ap.add_argument("--circuit", type=int, required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--prefix", help="verifier contract prefix (default Zkgen<circuitId>)")
    ap.add_argument("--max-power", type=int, default=int(os.environ.get("ZKGEN_MAX_POWER", 17)))
    ap.add_argument("--registry")
    ap.add_argument("--key", help="registry key to compare flatHash with (needs --registry)")
    ap.add_argument("--r1cs-only", action="store_true")
    a = ap.parse_args(argv)
    t0 = time.time()
    cpu = "0x" + a.processor.lower().removeprefix("0x").rjust(40, "0")
    prefix = a.prefix or f"Zkgen{a.circuit}"
    if not prefix.isidentifier():
        raise SystemExit("--prefix must be a Solidity identifier")
    out = os.path.abspath(a.out)
    os.makedirs(out, exist_ok=True)
    chain = Chain(a.rpc)

    log(f"[zkgen] chain {chain.chain_id}: reading {cpu}#{a.circuit} and its REF tree")
    top, resolve, subs, raw = load_tree(chain, cpu, a.circuit)
    fh = flat_hash(cpu, a.circuit, subs, raw)
    flat = flatten(top, resolve)
    nl = fold(flat)
    log(f"  {len(subs)} sub-circuits; flattened {flat.nand_count} gates, folded {nl.nand_count} gates "
        f"({nl.n_in} in / {nl.n_out} out); flatHash {fh}")
    if a.key:
        if not a.registry:
            raise SystemExit("--key needs --registry")
        reg = chain.registry_circuit(a.registry, a.key)
        ok = reg["flatHash"] == fh and reg["processor"] == cpu and reg["circuitId"] == a.circuit
        log(f"  registry {a.key}: flatHash {reg['flatHash']} -> {'MATCH' if ok else 'MISMATCH'}")
        if not ok:
            raise SystemExit("flatHash / circuit mismatch with the registry")
    with open(os.path.join(out, "folded.json"), "w") as f:
        json.dump({"name": NAME, "n_in": nl.n_in, "n_out": nl.n_out, "netlist": "0x" + encode(nl).hex(), "decode": {"kind": "bits"}}, f)
    with open(os.path.join(out, f"{NAME}.circom"), "w") as f:
        f.write(to_circom(nl, "ZkgenEval"))
    run("circom compile", [CIRCOM, f"{NAME}.circom", "--r1cs", "--wasm", "-o", "."], cwd=out)
    info = run("r1cs info", ["node", SNARK, "r1cs", "info", f"{NAME}.r1cs"], cwd=out)
    stats = {}
    for line in info.splitlines():
        if "# of" in line:
            k, v = line.split("# of ")[1].split(":")
            stats[k.strip()] = int(v)
    n_c, n_pub = stats["Constraints"], stats.get("Public Inputs", 0) + stats.get("Outputs", 0)
    power = need_power(n_c, n_pub)
    log(f"  {n_c:,} constraints, {n_pub} public inputs -> needs ptau 2^{power}")
    p, ptau = pick_ptau(power, a.max_power)
    n_pub_reg = len(_chunks(nl.n_in)) + len(_chunks(nl.n_out))
    manifest = {
        "tool": "zkgen", "version": 1, "chainId": chain.chain_id, "processor": cpu, "circuitId": a.circuit,
        "nIn": nl.n_in, "nOut": nl.n_out, "nPub": n_pub_reg,
        "subs": [{"processor": c, "circuitId": i} for c, i in subs], "flatHash": fh,
        "gates": {"flattened": flat.nand_count, "folded": nl.nand_count}, "constraints": n_c, "ptauPower": p,
    }
    if a.r1cs_only:
        json.dump(manifest, open(os.path.join(out, "manifest.json"), "w"), indent=1)
        print(json.dumps(manifest))
        return manifest
    run("groth16 ceremony", ["node", "--max-old-space-size=6144", os.path.join(ZK, "ceremony.cjs"), "run", out, NAME, prefix,
                             "--ptau", ptau, "--transcript", os.path.join(out, "transcript.json")])
    x = [0] * nl.n_in
    y = simulate(nl, x)
    with open(os.path.join(out, "sample.input.json"), "w") as f:
        json.dump(circom_input(x, y), f)
    snark_mod = os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(SNARK))), "")
    run("sample proof", ["node", "-e", PROVE_JS, snark_mod, f"{NAME}_js/{NAME}.wasm", f"{NAME}.zkey", "vk.json",
                         "sample.input.json", "sample.proof.json"], cwd=out)
    sp = json.load(open(os.path.join(out, "sample.proof.json")))
    sample = {"x": "0x" + pack_bits(x).hex(), "y": "0x" + pack_bits(y).hex(), **sp}
    json.dump(sample, open(os.path.join(out, "sample.json"), "w"))
    for f in ("sample.input.json", "sample.proof.json"):
        os.remove(os.path.join(out, f))
    vfile = f"{prefix}Groth16Verifier.sol"
    files = ["folded.json", f"{NAME}_js/{NAME}.wasm", f"{NAME}.zkey", "vk.json", vfile, "transcript.json", "sample.json", f"{NAME}.r1cs"]
    tr = json.load(open(os.path.join(out, "transcript.json")))
    manifest.update({
        "verifier": {"file": vfile, "contract": f"{prefix}Groth16Verifier"},
        "beacon": {k: tr["beacon"][k] for k in ("chainId", "number", "hash")},
        "files": {f: {"sha256": sha256(os.path.join(out, f)), "bytes": os.path.getsize(os.path.join(out, f))} for f in files},
        "sample": sample, "seconds": round(time.time() - t0, 1),
        "createdAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    })
    json.dump(manifest, open(os.path.join(out, "manifest.json"), "w"), indent=1)
    subs_arg = "[" + ",".join(f"({c},{i})" for c, i in subs) + "]"
    log(f"""
[zkgen] done in {manifest['seconds']} s: {out}
  zkey {manifest['files'][f'{NAME}.zkey']['bytes'] / 1e6:.1f} MB, wasm {manifest['files'][f'{NAME}_js/{NAME}.wasm']['bytes'] / 1e6:.1f} MB, \
{n_c:,} constraints (ptau 2^{p}), beacon X Layer block {tr['beacon']['number']}
Next steps:
  1. deploy the verifier (explicit gas; never estimate gas for verifier calls):
     forge create {out}/{vfile}:{prefix}Groth16Verifier --rpc-url <rpc> --broadcast --private-key <your key>
  2. register it (key = keccak256(abi.encode(processor, circuitId, verifier))):
     cast send <AlephRegistry> 'register(address,uint256,(address,uint256)[],address)' \\
       {cpu} {a.circuit} '{subs_arg}' <verifier> --rpc-url <rpc>
  3. prove: POST <prover>/prove {{"circuit": "<registry key>", "x": "0x.."}} (loads this job on demand), or locally with
     the zkey + wasm here; then AlephRegistry.verifyEval(key, x, y, proof) with gas 1,000,000.
  anyone can check the ceremony: node zk/ceremony.cjs verify {out} {NAME} --transcript {out}/transcript.json""")
    print(json.dumps({k: manifest[k] for k in ("chainId", "processor", "circuitId", "flatHash", "constraints", "subs")}))
    return manifest


if __name__ == "__main__":
    main()
