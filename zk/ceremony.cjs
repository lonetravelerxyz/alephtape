// Groth16 phase-2 ceremony for one circuit. Transparent, re-verifiable.
//
//   node --max-old-space-size=6144 zk/ceremony.cjs run <buildDir> <name> <Prefix> [--ptau <file>] [--transcript <file>]
//     1. groth16 setup  <name>.r1cs + ppot_0080_17.ptau (or --ptau) -> <name>_0000.zkey (deterministic)
//     2. one contribution with fresh OS entropy (in memory only)  -> <name>_0001.zkey
//     3. random beacon: hash of the latest finalized X Layer MAINNET block, 2^10 iterations -> <name>.zkey (final)
//     4. zkey verify final against r1cs + ptau (re-runs the whole chain)
//     5. export vk.json + <Prefix>Groth16Verifier.sol (snarkjs verifier + the uint256[24] wrapper AlephRegistry calls)
//     -> transcript zk/ceremony/<name>.json (committed; --transcript writes it elsewhere, e.g. zk/zkgen.py's job dir);
//        intermediate zkeys are deleted, the final zkey is an artifact.
//
//   node --max-old-space-size=6144 zk/ceremony.cjs verify <buildDir> <name> [--transcript <file>]
//     Anyone: checks r1cs / ptau / final zkey sha256 against the transcript, re-fetches the beacon block from X Layer
//     mainnet and checks its hash, then runs snarkjs zkey verify (same as `snarkjs zkey verify r1cs ptau zkey`),
//     prints every contribution hash, and checks vk.json matches the zkey.
"use strict";
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const snarkjs = require("snarkjs");

const ZK = __dirname;
const PTAU_DIR = process.env.PTAU_DIR || path.join(ZK, "ptau");
const PTAU = path.join(PTAU_DIR, "ppot_0080_17.ptau");
const ptauSource = (f) => `https://pse-trusted-setup-ppot.s3.eu-central-1.amazonaws.com/pot28_0080/${path.basename(f)}`;
const ptauPower = (f) => Number((/_(\d+)\.ptau$/.exec(f) || [])[1]);
const XLAYER_RPC = process.env.XLAYER_RPC || "https://rpc.xlayer.tech";
const BEACON_ITER_EXP = 10;
const TEMPLATE = path.join(ZK, "node_modules", "snarkjs", "templates", "verifier_groth16.sol.ejs");
const SNARKJS_VERSION = require(path.join(ZK, "node_modules", "snarkjs", "package.json")).version;

const sha256 = (f) => crypto.createHash("sha256").update(fs.readFileSync(f)).digest("hex");
const hex = (u8) => Buffer.from(u8).toString("hex");

function logger(lines) {
  const push = (lvl) => (...a) => { const s = a.join(" ").replace(/\s+/g, " ").trim(); lines.push(s);if (lvl !== "debug") console.error(`  ${s}`); };
  return { info: push("info"), warn: push("warn"), error: push("error"), debug: () => {} };
}

async function rpc(method, params) {
  const r = await fetch(XLAYER_RPC, { method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  const j = await r.json();
  if (j.error || !j.result) throw new Error(`${method}: ${JSON.stringify(j.error || j)}`);
  return j.result;
}

async function beaconBlock() {
  if ((await rpc("eth_chainId", [])) !== "0xc4") throw new Error("beacon RPC is not X Layer mainnet (196)");
  const b = await rpc("eth_getBlockByNumber", ["finalized", false]);
  return { chainId: 196, rpc: XLAYER_RPC, tag: "finalized", number: parseInt(b.number, 16), hash: b.hash, timestamp: parseInt(b.timestamp, 16) };
}

/** snarkjs Groth16 verifier renamed to <Prefix>Groth16Core + the 24-word wrapper the registry calls. */
function wrapVerifier(src, prefix, nPub) {
  if (!src.includes("contract Groth16Verifier {")) throw new Error("unexpected snarkjs verifier template");
  const core = `${prefix}Groth16Core`;
  const body = src.replace("contract Groth16Verifier {", `contract ${core} {`);
  return `${body}
/// AlephRegistry calls verifyProof(uint256[24], uint256[${nPub}]) (the PLONK-era interface, unchanged). A Groth16 proof is
/// 8 words in snarkjs exportSolidityCallData order (pA0, pA1, pB00, pB01, pB10, pB11, pC0, pC1; B already swapped for
/// the precompile) followed by 16 zero words. Non-zero padding is rejected so the padding cannot be malleated.
/// The generated verifier reads its arguments with calldata assembly and ends with return(), so it is reached through
/// an external self-call (STATICCALL), not an internal call.
contract ${prefix}Groth16Verifier is ${core} {
    error NonZeroPadding();

    function verifyProof(uint256[24] calldata p, uint256[${nPub}] calldata pub) external view returns (bool) {
        for (uint256 i = 8; i < 24; ++i) {
            if (p[i] != 0) revert NonZeroPadding();
        }
        return this.verifyProof([p[0], p[1]], [[p[2], p[3]], [p[4], p[5]]], [p[6], p[7]], pub);
    }
}
`;
}

async function run(buildDir, name, prefix, ptau = PTAU, transcript = path.join(ZK, "ceremony", `${name}.json`)) {
  const r1cs = path.join(buildDir, `${name}.r1cs`);
  const z0 = path.join(buildDir, `${name}_0000.zkey`);
  const z1 = path.join(buildDir, `${name}_0001.zkey`);
  const zf = path.join(buildDir, `${name}.zkey`);
  const log = [];
  const L = logger(log);
  const t0 = Date.now();
  const tr = { circuit: name, protocol: "groth16", curve: "bn128", snarkjs: SNARKJS_VERSION, startedAt: new Date().toISOString(),
    r1cs: { file: `${name}.r1cs`, sha256: sha256(r1cs) },
    ptau: { file: path.basename(ptau), sha256: sha256(ptau), source: ptauSource(ptau), note: `PSE perpetual powers of tau, contribution 0080, 2^${ptauPower(ptau)}` } };

  console.error(`[${name}] 1/5 groth16 setup`);
  await snarkjs.zKey.newZKey(r1cs, ptau, z0, L);
  tr.initial = { file: `${name}_0000.zkey`, sha256: sha256(z0), note: "deterministic: snarkjs groth16 setup r1cs ptau reproduces it" };

  console.error(`[${name}] 2/5 contribution (OS entropy, memory only)`);
  let entropy = crypto.randomBytes(64).toString("hex"); // snarkjs also mixes in its own 64 random bytes
  const c1 = await snarkjs.zKey.contribute(z0, z1, "AlephTape #1 (OS entropy, discarded)", entropy, L);
  entropy = null;
  tr.contribution = { name: "AlephTape #1 (OS entropy, discarded)", hash: hex(c1), sha256: sha256(z1) };

  const blk = await beaconBlock();
  console.error(`[${name}] 3/5 beacon: X Layer block ${blk.number} ${blk.hash}, 2^${BEACON_ITER_EXP} iterations`);
  const bh = await snarkjs.zKey.beacon(z1, zf, `X Layer mainnet block ${blk.number}`, blk.hash.replace(/^0x/, ""), BEACON_ITER_EXP, L);
  if (!bh) throw new Error("beacon failed");
  tr.beacon = { ...blk, iterationsExp: BEACON_ITER_EXP, name: `X Layer mainnet block ${blk.number}`, contributionHash: hex(bh) };

  console.error(`[${name}] 4/5 zkey verify against r1cs + ptau`);
  const vlog = [];
  if (!(await snarkjs.zKey.verifyFromR1cs(r1cs, ptau, zf, logger(vlog)))) throw new Error("zkey verify FAILED");
  tr.verify = { ok: true, log: vlog.filter((l) => /contribution|Hash|OK|beacon/i.test(l)) };

  console.error(`[${name}] 5/5 export vk + verifier`);
  const vk = await snarkjs.zKey.exportVerificationKey(zf);
  fs.writeFileSync(path.join(buildDir, "vk.json"), JSON.stringify(vk, null, 1));
  const sol = await snarkjs.zKey.exportSolidityVerifier(zf, { groth16: fs.readFileSync(TEMPLATE, "utf8") }, L);
  const vfile = `${prefix}Groth16Verifier.sol`;
  fs.writeFileSync(path.join(buildDir, vfile), wrapVerifier(sol, prefix, vk.nPublic));
  fs.rmSync(z0); fs.rmSync(z1);

  tr.final = { file: `${name}.zkey`, sha256: sha256(zf), bytes: fs.statSync(zf).size, note: "gitignored artifact; shipped in the prover image" };
  tr.vk = { file: "vk.json", sha256: sha256(path.join(buildDir, "vk.json")), nPublic: vk.nPublic };
  tr.verifier = { file: vfile, sha256: sha256(path.join(buildDir, vfile)), contract: `${prefix}Groth16Verifier` };
  tr.seconds = Math.round((Date.now() - t0) / 1000);
  tr.howToVerify = [
    `snarkjs zkey verify ${name}.r1cs ${path.basename(ptau)} ${name}.zkey   (or: node zk/ceremony.cjs verify <buildDir> ${name})`,
    "check the beacon: eth_getBlockByNumber(beacon.number) on X Layer mainnet (196) returns beacon.hash",
    "check the deployed verifier's constants: snarkjs zkey export solidityverifier on the same zkey",
  ];
  fs.mkdirSync(path.dirname(transcript), { recursive: true });
  fs.writeFileSync(transcript, JSON.stringify(tr, null, 1) + "\n");
  console.error(`[${name}] done in ${tr.seconds} s; final zkey ${(tr.final.bytes / 1e6).toFixed(1)} MB sha256 ${tr.final.sha256}`);
}

async function verify(buildDir, name, transcript = path.join(ZK, "ceremony", `${name}.json`)) {
  const tr = JSON.parse(fs.readFileSync(transcript));
  const ptau = path.join(PTAU_DIR, tr.ptau.file);
  const r1cs = path.join(buildDir, `${name}.r1cs`), zf = path.join(buildDir, `${name}.zkey`);
  const check = (what, got, want) => { if (got !== want) throw new Error(`${what}: ${got} != transcript ${want}`); console.error(`  ok ${what}`); };
  check("r1cs sha256", sha256(r1cs), tr.r1cs.sha256);
  check("ptau sha256", sha256(ptau), tr.ptau.sha256);
  check("final zkey sha256", sha256(zf), tr.final.sha256);
  const b = await rpc("eth_getBlockByNumber", ["0x" + tr.beacon.number.toString(16), false]);
  check(`beacon block ${tr.beacon.number} hash`, b.hash, tr.beacon.hash);
  const vlog = [];
  if (!(await snarkjs.zKey.verifyFromR1cs(r1cs, ptau, zf, logger(vlog)))) throw new Error("zkey verify FAILED");
  console.error("  ok zkey verify (r1cs + ptau + every contribution, incl. the beacon)");
  const vk = await snarkjs.zKey.exportVerificationKey(zf);
  check("vk.json", JSON.stringify(JSON.parse(fs.readFileSync(path.join(buildDir, "vk.json")))), JSON.stringify(vk));
}

(async () => {
  const argv = process.argv.slice(2);
  const opt = (k) => { const i = argv.indexOf(k); if (i < 0) return undefined; const v = argv[i + 1]; argv.splice(i, 2); return path.resolve(v); };
  const ptau = opt("--ptau"), transcript = opt("--transcript");
  const [cmd, buildDir, name, prefix] = argv;
  if (cmd === "run" && buildDir && name && prefix) await run(path.resolve(buildDir), name, prefix, ptau, transcript);
  else if (cmd === "verify" && buildDir && name) await verify(path.resolve(buildDir), name, transcript);
  else throw new Error("usage: ceremony.cjs run <buildDir> <name> <Prefix> [--ptau f] [--transcript f] | verify <buildDir> <name> [--transcript f]");
  process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });
