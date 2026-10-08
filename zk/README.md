# zk

Any circuit taped out on TapeOut's ℵ₀ → a Groth16 verifier you can register in AlephRegistry, and the ceremony
transcripts of every circuit we registered.

## Setup

- `npm i` in `zk/` (snarkjs 0.7.6).
- circom v2.2.3 → `zk/bin/circom`.
- PSE perpetual powers of tau, contribution 0080 → `zk/ptau/`:
  - `ppot_0080_14.ptau` sha256 `3ca1149e9349b22b0ee0649399cfb787677129b7b1189d1899fc0d615d9583db`
  - `ppot_0080_17.ptau` sha256 `f807e065fde53f72f4bf4d57140fab85b26daa6cc95bdfec7cce93622b3a367c`
- Optional: rapidsnark (iden3 release v0.0.8) on `PATH` or `RAPIDSNARK=<path>` for fast proving.

## zkgen: make your circuit verifiable

```bash
python3 zk/zkgen.py --rpc https://rpc.xlayer.tech --processor <addr> --circuit <id> --out <dir> \
    [--prefix Name] [--max-power 17] [--registry <AlephRegistry> --key <registry key>] [--r1cs-only]
```

- Reads the top netlist and every REF sub-circuit from the chain, computes the flatHash, flattens and folds the
  netlist (`circuits/netlist.py`), compiles the eval circuit (`compile.py`: public x and y, one constraint per NAND),
  picks the smallest ptau that fits and runs a Groth16 phase-2 ceremony (`ceremony.cjs`).
- Prints the next steps: deploy the verifier, then `register` it in AlephRegistry with the circuit's REF list.
- `--registry --key` compares the flatHash with the one the registry stores; `--r1cs-only` stops after the size check.
- LATCH (sequential) circuits are refused.

## Check a ceremony

```bash
node zk/ceremony.cjs verify <buildDir> <circuit> --transcript zk/ceremony/<circuit>.json
```

Checks the files against the transcript, re-fetches the beacon block from X Layer mainnet and runs `zkey verify`.
Each transcript in `ceremony/` names its ptau, r1cs hash, contribution hash, beacon block and the published final
zkey. Phase 2 is one contribution (OS entropy, never written to disk) plus a public X Layer block beacon; anyone can
add a contribution and register a new verifier.

Never use `eth_estimateGas` for snarkjs verifiers: they return `false` instead of reverting when starved of gas.
