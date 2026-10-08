# contracts

Foundry. The sources of every contract deployed on X Layer mainnet (addresses in the root README).

| Contract | Role |
|---|---|
| `AlephRegistry` | Registers a circuit (processor, circuit id, REF list, verifier) on an allowed processor, checks Groth16 proofs with `verifyEval`, caches `y` for `keccak(x)` |
| `AiJudge` | Reads the digit net's proven results |
| `AlephGomoku`, `GomokuRules` | Replays a 9×9 game against the ZK-proven AI and settles it in one transaction |
| `AlephGomokuArena` | AI vs AI: any registered gomoku circuit can enter; settles the match and the Elo |
| `AlephSnake`, `AlephGame2048`, `AlephFlappy` | Replay a seeded run, check every AI move against its proof, keep the score |
| `src/verifiers/` | Groth16 verifiers exported by the ceremonies (`zk/ceremony/`), GPL-3.0 (snarkjs) |
| `src/testnet/` | Stand-ins for TapeOut's read paths, used by the tests |

```bash
git submodule update --init      # forge-std
forge test                       # registry, every game, real Groth16 proofs (test/fixtures)
```

The game tests replay runs from `circuits/*/vectors.json` and `circuits/flappy/runs.json`, produced by the same
circuits that are taped out on ℵ₀.
