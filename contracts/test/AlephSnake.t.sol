// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {AlephSnake} from "../src/AlephSnake.sol";
import {AlephGame2048} from "../src/AlephGame2048.sol";
import {AlephFlappy} from "../src/AlephFlappy.sol";
import {AlephRegistry} from "../src/AlephRegistry.sol";
import {MockFactory, MockProcessor} from "./mocks/MockTapeOut.sol";
import {MockAlephEval, GasBurnVerifier} from "./mocks/MockAlephEval.sol";

/// Spec S1–S8. Runs come from circuits/snake/vectors.json: 30 sprints of the real
/// AI (Python engine + integer model), with every move's x, the circuit's y and needsProof. The contract re-derives
/// x from its own replay (food from keccak), so a settled vector run is the Solidity == Python engine check.
contract AlephSnakeTest is Test {
    using stdJson for string;

    bytes32 constant KEY = keccak256("snake");
    /// Seeds are bound to no address: the tests settle even vector runs as ALICE and odd ones as BOB.
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    MockAlephEval mock;
    AlephSnake snake;
    string vecStore;

    struct RunVec {
        address player;
        uint256 nonce;
        bytes32 seed;
        bytes actions;
        uint256 score;
        uint256 moves;
        bytes[] x;
        bytes[] y;
        bool[] need;
    }

    function setUp() public {
        mock = new MockAlephEval();
        snake = new AlephSnake(address(mock), KEY);
        vecStore = vm.readFile(string.concat(vm.projectRoot(), "/../circuits/snake/vectors.json"));
    }

    // ------------------------------------------------------------------ helpers
    function _vec() internal view returns (string memory) {
        return vecStore;
    }

    function _run(uint256 i) internal view returns (RunVec memory r) {
        string memory vec = _vec(); // one memory copy of the storage string per run
        string memory p = string.concat(".games[", vm.toString(i), "]");
        r.player = i % 2 == 0 ? ALICE : BOB;
        r.nonce = vec.readUint(string.concat(p, ".nonce"));
        r.seed = vec.readBytes32(string.concat(p, ".seed"));
        r.actions = vec.readBytes(string.concat(p, ".actions"));
        r.score = vec.readUint(string.concat(p, ".score"));
        r.moves = vec.readUint(string.concat(p, ".moves"));
        r.x = vec.readBytesArray(string.concat(p, ".x"));
        r.y = vec.readBytesArray(string.concat(p, ".y"));
        r.need = vec.readBoolArray(string.concat(p, ".needsProof"));
    }

    function _nRuns() internal view returns (uint256 n) {
        string memory vec = _vec();
        while (vm.keyExistsJson(vec, string.concat(".games[", vm.toString(n), "]"))) ++n;
    }

    /// Plies for a run: the circuit's y on every move that needs a proof (mock truth = that y), empty on rule moves.
    function _plies(RunVec memory r) internal returns (AlephSnake.AiPly[] memory plies) {
        plies = new AlephSnake.AiPly[](r.moves);
        for (uint256 m; m < r.moves; ++m) {
            if (!r.need[m]) continue;
            mock.setTruth(r.x[m], r.y[m]);
            plies[m].y = r.y[m];
        }
    }

    function _count(bool[] memory b) internal pure returns (uint256 n) {
        for (uint256 i; i < b.length; ++i) {
            if (b[i]) ++n;
        }
    }

    /// Moves that reach verifyEval: positions needing a proof, counted once (a repeated view is cached by then).
    function _distinctNeed(RunVec memory r) internal pure returns (uint256 n) {
        for (uint256 m; m < r.moves; ++m) {
            if (!r.need[m]) continue;
            bool seen;
            for (uint256 k; k < m && !seen; ++k) {
                seen = r.need[k] && keccak256(r.x[k]) == keccak256(r.x[m]);
            }
            if (!seen) ++n;
        }
    }

    /// The N_MAX-move (24) run with the most moves to prove (vectors.json longRun).
    function _longRun() internal view returns (uint256) {
        return _vec().readUint(".longRun");
    }

    /// The first vector run that dies before N_MAX (vectors.json deadRun, -1 if none).
    function _deadRun() internal view returns (int256) {
        return _vec().readInt(".deadRun");
    }

    function _firstNeed(RunVec memory r) internal pure returns (uint256 m) {
        while (!r.need[m]) ++m;
    }

    function _firstRule(RunVec memory r) internal pure returns (uint256 m) {
        while (m < r.moves && r.need[m]) ++m;
    }

    // ------------------------------------------------------------------ S1: a real AI run settles
    function test_S1_runSettlesAndRecordsBest() public {
        RunVec memory r = _run(0);
        AlephSnake.AiPly[] memory plies = _plies(r);
        assertEq(snake.seedOf(r.nonce), r.seed);
        vm.expectEmit(true, true, false, true, address(snake));
        emit AlephSnake.RunSettled(r.player, r.seed, r.score, r.moves);
        vm.prank(r.player);
        assertEq(snake.settle(r.nonce, r.actions, plies), r.score);
        assertEq(snake.bestScore(r.player), r.score);
        assertTrue(snake.settled(r.seed));
        assertEq(mock.verifyCalls(), _distinctNeed(r));
        assertEq(mock.lastKey(), KEY);
    }

    /// Settles vector run i as its test player (ALICE or BOB); external so each run gets fresh memory. Returns (score, moves, proofs).
    function settleVector(uint256 i) external returns (uint256, uint256, uint256) {
        RunVec memory r = _run(i);
        AlephSnake.AiPly[] memory plies = _plies(r);
        vm.prank(r.player);
        assertEq(snake.settle(r.nonce, r.actions, plies), r.score, string.concat("run ", vm.toString(i)));
        assertEq(snake.bestScore(r.player) >= r.score, true);
        return (r.score, r.moves, _count(r.need));
    }

    /// Every vector run (Python engine + model) replays to the same score and length on-chain.
    function test_S1b_allVectorRunsMatchPython() public {
        uint256 n = _nRuns();
        assertGe(n, 30);
        uint256 total;
        uint256 proofs;
        uint256 moves;
        for (uint256 i; i < n; ++i) {
            (uint256 sc, uint256 mv, uint256 pr) = this.settleVector(i);
            total += sc;
            moves += mv;
            proofs += pr;
        }
        emit log_named_uint("vector runs settled", n);
        emit log_named_uint("food eaten (sum)", total);
        emit log_named_uint("moves (sum)", moves);
        emit log_named_uint("moves needing a proof (sum)", proofs);
    }

    function test_S1c_bestScoreKeepsMax() public {
        uint256 n = _nRuns();
        uint256 best;
        address p = _run(0).player;
        // even runs are all settled by ALICE
        for (uint256 i; i < n; i += 2) {
            (uint256 sc,,) = this.settleVector(i);
            if (sc > best) best = sc;
            assertEq(snake.bestScore(p), best);
        }
    }

    // ------------------------------------------------------------------ S2: a wrong action or a bad proof reverts
    function test_S2_wrongActionReverts() public {
        RunVec memory r = _run(0);
        AlephSnake.AiPly[] memory plies = _plies(r);
        uint256 m = _firstNeed(r);
        bytes memory bad = bytes.concat(r.actions);
        bad[m] = bytes1((uint8(bad[m]) + 1) % 3);
        vm.prank(r.player);
        vm.expectRevert(abi.encodeWithSelector(AlephSnake.WrongAction.selector, m));
        snake.settle(r.nonce, bad, plies);
    }

    function test_S2b_ruleMoveMustBeTheSafeAction() public {
        RunVec memory r = _run(0);
        uint256 m = _firstRule(r);
        if (m == r.moves) return;
        AlephSnake.AiPly[] memory plies = _plies(r);
        bytes memory bad = bytes.concat(r.actions);
        bad[m] = bytes1((uint8(bad[m]) + 1) % 3);
        vm.prank(r.player);
        vm.expectRevert(abi.encodeWithSelector(AlephSnake.WrongAction.selector, m));
        snake.settle(r.nonce, bad, plies);
    }

    function test_S2c_tamperedYReverts() public {
        RunVec memory r = _run(0);
        AlephSnake.AiPly[] memory plies = _plies(r);
        uint256 m = _firstNeed(r);
        plies[m].y = hex"7f7f1f"; // all three scores 127: a y the circuit did not output
        vm.prank(r.player);
        vm.expectRevert(MockAlephEval.InvalidProof.selector);
        snake.settle(r.nonce, r.actions, plies);
    }

    function test_S2d_registryFalseReverts() public {
        RunVec memory r = _run(0);
        AlephSnake.AiPly[] memory plies = _plies(r);
        mock.setReturnFalse(true);
        vm.prank(r.player);
        vm.expectRevert(abi.encodeWithSelector(AlephSnake.ProofRejected.selector, _firstNeed(r)));
        snake.settle(r.nonce, r.actions, plies);
    }

    function test_S2e_otherNonceCannotReuseTheRun() public {
        RunVec memory r = _run(0);
        AlephSnake.AiPly[] memory plies = _plies(r);
        vm.prank(r.player); // same actions, other nonce: other seed, other food -> the actions diverge
        vm.expectRevert();
        snake.settle(r.nonce + 1, r.actions, plies);
    }

    // ------------------------------------------------------------------ S3: bad input
    function test_S3_badActionByte() public {
        RunVec memory r = _run(0);
        AlephSnake.AiPly[] memory plies = _plies(r);
        bytes memory bad = bytes.concat(r.actions);
        bad[0] = bytes1(uint8(3));
        vm.prank(r.player);
        vm.expectRevert(abi.encodeWithSelector(AlephSnake.BadAction.selector, 0));
        snake.settle(r.nonce, bad, plies);
    }

    function test_S3b_selectBadInput() public {
        vm.expectRevert(AlephSnake.BadInput.selector);
        snake.select(hex"00", hex"000000");
        vm.expectRevert(AlephSnake.BadInput.selector);
        snake.select(hex"0000000000000000", hex"0000");
        vm.expectRevert(AlephSnake.BadInput.selector);
        snake.select(hex"0000000000000000", hex"000020"); // bit 21 set: non-canonical
        vm.expectRevert(AlephSnake.BadInput.selector);
        snake.needsProof(hex"00000000000000");
    }

    // ------------------------------------------------------------------ S4: registry cache
    function test_S4_cachedSkipsVerify() public {
        RunVec memory r = _run(0);
        for (uint256 m; m < r.moves; ++m) {
            if (r.need[m]) mock.setCached(r.x[m], r.y[m]);
        }
        AlephSnake.AiPly[] memory empty = new AlephSnake.AiPly[](r.moves);
        vm.prank(r.player);
        assertEq(snake.settle(r.nonce, r.actions, empty), r.score);
        assertEq(mock.verifyCalls(), 0);
    }

    function test_S4b_missingProofReverts() public {
        RunVec memory r = _run(0);
        AlephSnake.AiPly[] memory empty = new AlephSnake.AiPly[](r.moves);
        vm.prank(r.player);
        vm.expectRevert(abi.encodeWithSelector(AlephSnake.MissingProof.selector, _firstNeed(r)));
        snake.settle(r.nonce, r.actions, empty);
    }

    // ------------------------------------------------------------------ S5: a seed settles once
    function test_S5_sameSeedTwiceReverts() public {
        RunVec memory r = _run(0);
        AlephSnake.AiPly[] memory plies = _plies(r);
        vm.prank(r.player);
        snake.settle(r.nonce, r.actions, plies);
        vm.prank(r.player);
        vm.expectRevert(AlephSnake.AlreadySettled.selector);
        snake.settle(r.nonce, r.actions, plies);
    }

    /// A seed is global. A run "played" by one address (a guest) settles from any other, which gets the credit;
    /// after that nobody can settle the seed again, the original player included.
    function test_S5b_anyAddressSettlesOnceGlobally() public {
        RunVec memory r = _run(0);
        AlephSnake.AiPly[] memory plies = _plies(r);
        address guest = address(0xdEaD);
        address wallet = address(0xBEEF);
        vm.expectEmit(true, true, false, true, address(snake));
        emit AlephSnake.RunSettled(wallet, r.seed, r.score, r.moves);
        vm.prank(wallet);
        assertEq(snake.settle(r.nonce, r.actions, plies), r.score);
        assertEq(snake.bestScore(wallet), r.score);
        assertEq(snake.bestScore(guest), 0);
        vm.prank(guest);
        vm.expectRevert(AlephSnake.AlreadySettled.selector);
        snake.settle(r.nonce, r.actions, plies);
        vm.prank(ALICE);
        vm.expectRevert(AlephSnake.AlreadySettled.selector);
        snake.settle(r.nonce, r.actions, plies);
    }

    /// Seed = keccak256(abi.encode(keccak256("AlephTape.snake.v2"), nonce)); golden values shared with Python / TS.
    function test_S5c_seedDomain() public view {
        assertEq(snake.SEED_DOMAIN(), 0xb6ecca020c15f3090fee6f1521fb61ed6615c8b877c5861a7693207ac9624fbe);
        assertEq(snake.seedOf(7), 0xd1164e49cab1e7a5c01a9fbdd94f8a16388a5e473ec27e31031aed073e3cb3c9);
        assertEq(snake.seedOf(7), keccak256(abi.encode(keccak256("AlephTape.snake.v2"), uint256(7))));
    }

    /// The three games' seed domains differ, so one nonce gives three unrelated seeds.
    function test_S5d_seedDomainsDifferPerGame() public {
        AlephGame2048 g2048 = new AlephGame2048(address(mock), KEY, 6, 64);
        AlephFlappy flappy = new AlephFlappy(address(mock), KEY);
        bytes32 a = snake.SEED_DOMAIN();
        bytes32 b = g2048.SEED_DOMAIN();
        bytes32 c = flappy.SEED_DOMAIN();
        assertTrue(a != b && b != c && a != c);
        for (uint256 n; n < 3; ++n) {
            assertTrue(snake.seedOf(n) != g2048.seedOf(n) && g2048.seedOf(n) != flappy.seedOf(n));
            assertTrue(snake.seedOf(n) != flappy.seedOf(n));
        }
    }

    // ------------------------------------------------------------------ S6: the run must be complete, nothing after
    function test_S6_truncatedRunNotFinished() public {
        RunVec memory r = _run(0);
        AlephSnake.AiPly[] memory plies = _plies(r);
        uint256 k = r.moves - 1;
        bytes memory cut = new bytes(k);
        for (uint256 m; m < k; ++m) {
            cut[m] = r.actions[m];
        }
        AlephSnake.AiPly[] memory p2 = new AlephSnake.AiPly[](k);
        for (uint256 m; m < k; ++m) {
            p2[m] = plies[m];
        }
        vm.prank(r.player);
        vm.expectRevert(AlephSnake.NotFinished.selector);
        snake.settle(r.nonce, cut, p2);
    }

    function test_S6b_movesAfterEnd() public {
        RunVec memory r = _run(_longRun());
        assertEq(r.moves, 24);
        assertEq(snake.N_MAX(), 24);
        AlephSnake.AiPly[] memory plies = _plies(r);
        AlephSnake.AiPly[] memory p2 = new AlephSnake.AiPly[](r.moves + 1);
        for (uint256 m; m < r.moves; ++m) {
            p2[m] = plies[m];
        }
        vm.prank(r.player);
        vm.expectRevert(abi.encodeWithSelector(AlephSnake.MovesAfterEnd.selector, 24));
        snake.settle(r.nonce, bytes.concat(r.actions, hex"00"), p2);
    }

    function test_S6c_movesAfterDeath() public {
        int256 d = _deadRun();
        if (d < 0) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        RunVec memory r = _run(uint256(d)); // d >= 0
        AlephSnake.AiPly[] memory plies = _plies(r);
        AlephSnake.AiPly[] memory p2 = new AlephSnake.AiPly[](r.moves + 1);
        for (uint256 m; m < r.moves; ++m) {
            p2[m] = plies[m];
        }
        vm.prank(r.player);
        vm.expectRevert(abi.encodeWithSelector(AlephSnake.MovesAfterEnd.selector, r.moves));
        snake.settle(r.nonce, bytes.concat(r.actions, hex"00"), p2);
    }

    function test_S6d_plyCount() public {
        RunVec memory r = _run(0);
        AlephSnake.AiPly[] memory plies = new AlephSnake.AiPly[](r.moves - 1);
        vm.expectRevert(AlephSnake.PlyCount.selector);
        snake.settle(r.nonce, r.actions, plies);
    }

    // ------------------------------------------------------------------ S7: gas (real AlephRegistry)
    /// Gas a GasBurnVerifier burns per call: SnakeGroth16Verifier.verifyProof measured ~200k (test_realProofRun logs it).
    uint256 constant VERIFIER_BURN = 210_000;

    function _realRegistry(address verifier) internal returns (AlephRegistry reg, bytes32 key) {
        MockFactory factory = new MockFactory();
        MockProcessor proc = new MockProcessor(address(factory));
        factory.setCPU(address(proc), true);
        proc.put(73, hex"02abababababababababababababababababababababab", 64, 21);
        reg = new AlephRegistry(address(factory));
        reg.allowProcessor(address(proc));
        key = reg.register(address(proc), 73, new AlephRegistry.CircuitRef[](0), verifier);
    }

    function _gasFor(uint256 moves, uint256 toVerify) internal view returns (uint256) {
        return snake.gasLimitFor(moves, toVerify);
    }

    function test_S7_fullSprintGas() public {
        (AlephRegistry reg, bytes32 key) = _realRegistry(address(new GasBurnVerifier(VERIFIER_BURN)));
        assertEq(reg.circuit(key).nPub, 2);
        AlephSnake s = new AlephSnake(address(reg), key);
        RunVec memory r = _run(_longRun());
        AlephSnake.AiPly[] memory plies = new AlephSnake.AiPly[](r.moves);
        for (uint256 m; m < r.moves; ++m) {
            if (r.need[m]) plies[m].y = r.y[m];
        }
        uint256 n = _distinctNeed(r);
        uint256 gasLimit = _gasFor(r.moves, n); // documented formula: distinct uncached positions
        vm.prank(r.player);
        uint256 before = gasleft();
        uint256 score = s.settle{gas: gasLimit}(r.nonce, r.actions, plies);
        uint256 used = before - gasleft();
        assertEq(score, r.score);
        emit log_named_uint("full sprint moves", r.moves);
        emit log_named_uint("moves verified (verifier burns 210k each)", n);
        emit log_named_uint("rule moves", r.moves - n);
        emit log_named_uint("settle gas", used);
        emit log_named_uint("per verified move (avg)", used / n);
        emit log_named_uint("gas limit (formula)", gasLimit);
        emit log_named_uint("calldata bytes", abi.encodeCall(AlephSnake.settle, (r.nonce, r.actions, plies)).length);
        assertLt(used, gasLimit);
    }

    function test_S7b_cachedSprintGas() public {
        (AlephRegistry reg, bytes32 key) = _realRegistry(address(new GasBurnVerifier(VERIFIER_BURN)));
        AlephSnake s = new AlephSnake(address(reg), key);
        RunVec memory r = _run(_longRun());
        uint256[24] memory zero;
        for (uint256 m; m < r.moves; ++m) {
            if (!r.need[m]) continue;
            (bool done,) = reg.getResult(key, r.x[m]);
            if (!done) reg.verifyEval(key, r.x[m], r.y[m], zero);
        }
        AlephSnake.AiPly[] memory empty = new AlephSnake.AiPly[](r.moves);
        uint256 gasLimit = _gasFor(r.moves, 0);
        vm.prank(r.player);
        uint256 before = gasleft();
        s.settle{gas: gasLimit}(r.nonce, r.actions, empty);
        emit log_named_uint("settle gas, every move cached", before - gasleft());
    }

    function test_S7c_tooLittleGasReverts() public {
        (AlephRegistry reg, bytes32 key) = _realRegistry(address(new GasBurnVerifier(VERIFIER_BURN)));
        AlephSnake s = new AlephSnake(address(reg), key);
        RunVec memory r = _run(0);
        AlephSnake.AiPly[] memory plies = new AlephSnake.AiPly[](r.moves);
        for (uint256 m; m < r.moves; ++m) {
            if (r.need[m]) plies[m].y = r.y[m];
        }
        uint256 gasLimit = _gasFor(r.moves, _distinctNeed(r));
        vm.prank(r.player);
        vm.expectRevert(); // InsufficientGas inside the registry, or out of gas
        s.settle{gas: gasLimit / 2}(r.nonce, r.actions, plies);
        vm.prank(r.player);
        assertEq(s.settle{gas: gasLimit}(r.nonce, r.actions, plies), r.score);
    }

    // ------------------------------------------------------------------ S8: rule moves need no proof
    function test_S8_ruleMovesIgnorePliesAndRegistry() public {
        RunVec memory r = _run(_vec().readUint(".ruleRun"));
        AlephSnake.AiPly[] memory plies = _plies(r);
        uint256 rules;
        for (uint256 m; m < r.moves; ++m) {
            if (r.need[m]) continue;
            ++rules;
            plies[m].y = rules % 2 == 0 ? bytes(hex"deadbeef") : bytes(hex"7f0000"); // garbage / a y for "straight"
            plies[m].proof[0] = 0xbad;
            vm.mockCallRevert(
                address(mock),
                abi.encodeWithSelector(MockAlephEval.getResult.selector, KEY, r.x[m]),
                "rule move read the registry"
            );
        }
        assertGt(rules, 0);
        vm.prank(r.player);
        assertEq(snake.settle(r.nonce, r.actions, plies), r.score);
        assertEq(mock.verifyCalls(), _distinctNeed(r));
        emit log_named_uint("rule moves (no proof, no registry read)", rules);
    }

    function test_S8b_needsProofOnSafetyCount() public view {
        // straight = bit 17, left = bit 23, right = bit 24 (1 = dies)
        assertTrue(snake.needsProof(hex"0000000000000000")); // three safe
        assertTrue(snake.needsProof(hex"0000820100000000")); // none safe (bits 17, 23, 24)
        assertTrue(snake.needsProof(hex"0000020000000000")); // straight dies, left + right safe
        assertFalse(snake.needsProof(hex"0000800100000000")); // only straight safe
        assertEq(snake.select(hex"0000800100000000", hex"00c01f"), 0); // forced straight whatever the scores
        assertEq(snake.select(hex"0000820100000000", hex"00c01f"), 2); // none safe: max over all three (right 127)
        assertEq(snake.select(hex"0000000000000000", hex"850200"), 0); // tie 5/5 -> straight
        assertEq(snake.select(hex"0000020000000000", hex"7fc000"), 2); // straight dies: left 0 / right 3 -> right
    }

    // ------------------------------------------------------------------ reference vectors (Python / prover / web)
    function test_referenceVectors() public view {
        string memory vec = _vec();
        bytes[] memory xs = vec.readBytesArray(".positions.x");
        bytes[] memory ys = vec.readBytesArray(".positions.y");
        uint256[] memory acts = vec.readUintArray(".positions.action");
        bool[] memory need = vec.readBoolArray(".positions.needsProof");
        assertEq(xs.length, 1000);
        uint256 proofs;
        for (uint256 i; i < xs.length; ++i) {
            assertEq(snake.select(xs[i], ys[i]), acts[i], string.concat("vector ", vm.toString(i)));
            assertEq(snake.needsProof(xs[i]), need[i]);
            if (need[i]) ++proofs;
        }
        assertEq(proofs, 800); // 700 with >= 2 safe actions + 100 with none; 200 rule positions
    }

    // ------------------------------------------------------------------ real proofs
    /// test/fixtures/snake_proofs.json: {nonce, actions, cases: [{xHex, yHex, pub, proof[24]}]} with one case
    /// per move that needs a proof; verified by the real SnakeGroth16Verifier behind the real AlephRegistry.
    function test_realProofRun() public {
        string memory path = string.concat(vm.projectRoot(), "/test/fixtures/snake_proofs.json");
        if (!vm.exists(path)) {
            vm.skip(true, "test/fixtures/snake_proofs.json not present yet");
            return;
        }
        string memory fx = vm.readFile(path);
        address verifier = vm.deployCode("SnakeGroth16Verifier.sol:SnakeGroth16Verifier");
        (AlephRegistry reg, bytes32 key) = _realRegistry(verifier);
        AlephSnake s = new AlephSnake(address(reg), key);
        (AlephSnake.AiPly[] memory plies, uint256[] memory at) = _fixturePlies(fx);
        (uint256 score, uint256 used) = _settleFixture(s, fx, plies, at.length);
        assertEq(score, fx.readUint(".score"));
        emit log_named_uint("real-proof run score", score);
        emit log_named_uint("real-proof run moves", plies.length);
        emit log_named_uint("real-proof moves verified", at.length);
        emit log_named_uint("real-proof settle gas", used);
        _logVerifierGas(verifier, fx, plies[at[0]].proof);
    }

    function _settleFixture(AlephSnake s, string memory fx, AlephSnake.AiPly[] memory plies, uint256 toVerify)
        internal
        returns (uint256 score, uint256 used)
    {
        uint256 nonce = fx.readUint(".nonce");
        bytes memory actions = fx.readBytes(".actions");
        uint256 gasLimit = _gasFor(actions.length, toVerify); // before the prank: it is an external call
        vm.prank(address(0xBEEF)); // any address: the seed is bound to none
        uint256 before = gasleft();
        score = s.settle{gas: gasLimit}(nonce, actions, plies);
        used = before - gasleft();
    }

    function _fixturePlies(string memory fx)
        internal
        view
        returns (AlephSnake.AiPly[] memory plies, uint256[] memory at)
    {
        at = fx.readUintArray(".proofMoves");
        plies = new AlephSnake.AiPly[](fx.readBytes(".actions").length);
        for (uint256 i; i < at.length; ++i) {
            string memory p = string.concat(".cases[", vm.toString(i), "]");
            plies[at[i]].y = fx.readBytes(string.concat(p, ".yHex"));
            bytes32[] memory w = fx.readBytes32Array(string.concat(p, ".proof"));
            for (uint256 k; k < 24; ++k) {
                plies[at[i]].proof[k] = uint256(w[k]);
            }
        }
    }

    /// SnakeGroth16Verifier.verifyProof alone (24-word wrapper + self-call into the snarkjs verifier, 2 public inputs).
    function _logVerifierGas(address verifier, string memory fx, uint256[24] memory proof) internal {
        uint256[] memory pv = fx.readUintArray(".cases[0].pub");
        uint256[2] memory pub = [pv[0], pv[1]];
        uint256 g0 = gasleft();
        (bool ok, bytes memory ret) =
            verifier.staticcall(abi.encodeWithSignature("verifyProof(uint256[24],uint256[2])", proof, pub));
        uint256 vg = g0 - gasleft();
        assertTrue(ok && abi.decode(ret, (bool)), "real proof must verify");
        emit log_named_uint("SnakeGroth16Verifier.verifyProof gas (warm address)", vg);
    }
}
