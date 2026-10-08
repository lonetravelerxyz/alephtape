// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {AlephFlappy} from "../src/AlephFlappy.sol";
import {AlephRegistry} from "../src/AlephRegistry.sol";
import {MockFactory, MockProcessor} from "./mocks/MockTapeOut.sol";
import {MockAlephEval, GasBurnVerifier} from "./mocks/MockAlephEval.sol";

/// Spec F1–F7. Runs come from the Python game (circuits/flappy/runs.json: BNN sprints
/// that survive 32 ticks and random-policy runs that crash); every tick gets a crafted y whose decision equals the
/// recorded action, and the mock registry only accepts y for the exact x the Python game produced. So a settle that
/// succeeds proves the contract's pipes, screens, tick order and scoring equal the Python reference.
contract AlephFlappyTest is Test {
    using stdJson for string;

    bytes32 constant KEY = keccak256("flappy");
    /// Seeds are bound to no address: the tests settle every runs.json run as PLAYER unless they say otherwise.
    address constant PLAYER = address(0xC3C3);
    MockAlephEval mock;
    AlephFlappy game;
    string runs;

    struct Run {
        address player;
        uint256 nonce;
        bytes32 seed;
        bytes actions;
        bytes[] xs;
        uint256 score;
        uint256 ticks;
        bool crashed;
    }

    function setUp() public {
        mock = new MockAlephEval();
        game = new AlephFlappy(address(mock), KEY);
        runs = vm.readFile(string.concat(vm.projectRoot(), "/../circuits/flappy/runs.json"));
    }

    // ------------------------------------------------------------------ helpers
    function _run(uint256 i) internal view returns (Run memory r) {
        string memory p = string.concat("$[", vm.toString(i), "]");
        r.player = PLAYER;
        r.nonce = runs.readUint(string.concat(p, ".nonce"));
        r.seed = runs.readBytes32(string.concat(p, ".seed"));
        r.actions = runs.readBytes(string.concat(p, ".actions"));
        r.xs = runs.readBytesArray(string.concat(p, ".xs"));
        r.score = runs.readUint(string.concat(p, ".score"));
        r.ticks = runs.readUint(string.concat(p, ".ticks"));
        r.crashed = runs.readBool(string.concat(p, ".crashed"));
    }

    function _nRuns() internal view returns (uint256 n) {
        while (vm.keyExistsJson(runs, string.concat("$[", vm.toString(n), "]"))) ++n;
    }

    /// First run with the wanted outcome.
    function _find(bool crashed) internal view returns (Run memory r) {
        uint256 n = _nRuns();
        for (uint256 i; i < n; ++i) {
            r = _run(i);
            if (r.crashed == crashed) return r;
        }
        revert("no such run");
    }

    function _act(bytes memory actions, uint256 t) internal pure returns (bool) {
        return (uint8(actions[t >> 3]) >> (t & 7)) & 1 == 1;
    }

    /// y whose decision is `flap`: (s_noflap, s_flap) = (0, 1) or (1, 0).
    function _y(bool flap) internal pure returns (bytes memory) {
        return flap ? bytes(hex"8000") : bytes(hex"0100");
    }

    /// Plies with crafted y; the mock accepts exactly (x_t, y_t).
    function _plies(Run memory r) internal returns (AlephFlappy.AiPly[] memory plies) {
        plies = new AlephFlappy.AiPly[](r.ticks);
        for (uint256 t; t < r.ticks; ++t) {
            bytes memory y = _y(_act(r.actions, t));
            mock.setTruth(r.xs[t], y);
            plies[t].y = y;
        }
    }

    /// Distinct screens of a run (a screen can repeat: the registry cache then serves the later ticks).
    function _distinct(Run memory r) internal pure returns (uint256 n) {
        for (uint256 t; t < r.ticks; ++t) {
            bool seen;
            for (uint256 u; u < t && !seen; ++u) {
                seen = keccak256(r.xs[u]) == keccak256(r.xs[t]);
            }
            if (!seen) ++n;
        }
    }

    // ------------------------------------------------------------------ F1: a run settles, rules == Python
    function test_F1_fullSprintSettles() public {
        Run memory r = _find(false);
        assertEq(r.ticks, 32);
        AlephFlappy.AiPly[] memory plies = _plies(r);
        vm.expectEmit(true, true, false, true, address(game));
        emit AlephFlappy.RunSettled(r.player, r.seed, uint8(r.score), 32);
        vm.prank(r.player);
        (uint8 score, uint8 ticks) = game.settle(r.nonce, r.actions, plies);
        assertEq(score, r.score);
        assertEq(score, 7);
        assertEq(ticks, 32);
        assertEq(game.bestScore(r.player), 7);
        assertTrue(game.settled(r.seed));
        assertEq(mock.lastKey(), KEY);
        assertEq(game.registry(), address(mock));
        assertEq(game.circuitKey(), KEY);
        assertEq(mock.verifyCalls(), _distinct(r), "a repeated screen is verified once, then read from the cache");
    }

    function test_F1b_crashRunSettles() public {
        Run memory r = _find(true);
        assertLt(r.ticks, 32);
        AlephFlappy.AiPly[] memory plies = _plies(r);
        vm.prank(r.player);
        (uint8 score, uint8 ticks) = game.settle(r.nonce, r.actions, plies);
        assertEq(score, r.score);
        assertEq(ticks, r.ticks);
        assertEq(game.bestScore(r.player), r.score);
    }

    /// Every run in runs.json (12 BNN sprints, 12 coin-flip crashes) settles with the Python score and length.
    function test_F1c_allRunsMatchPython() public {
        uint256 n = _nRuns();
        assertGe(n, 20);
        for (uint256 i; i < n; ++i) {
            Run memory r = _run(i);
            mock = new MockAlephEval(); // a fresh registry per run: the coin-flip "AIs" disagree with each other
            game = new AlephFlappy(address(mock), KEY);
            assertEq(game.seedOf(r.nonce), r.seed, "seed");
            uint256[] memory gp = runs.readUintArray(string.concat("$[", vm.toString(i), "].gaps"));
            uint8[8] memory g = game.gaps(r.seed);
            assertEq(gp.length, 8);
            for (uint256 k; k < 8; ++k) {
                assertEq(g[k], gp[k], "gap");
            }
            for (uint256 t; t < r.ticks; ++t) {
                uint256 row;
                while (uint8(r.xs[t][row]) & 1 == 0) ++row; // bird marker in column 0
                assertEq(game.screen(r.seed, t, row), r.xs[t], "screen");
            }
            AlephFlappy.AiPly[] memory plies = _plies(r); // before the prank: setTruth is a call too
            vm.prank(r.player);
            (uint8 score, uint8 ticks) = game.settle(r.nonce, r.actions, plies);
            assertEq(score, r.score, string.concat("score run ", vm.toString(i)));
            assertEq(ticks, r.ticks, string.concat("ticks run ", vm.toString(i)));
            assertEq(game.bestScore(r.player), r.score);
        }
    }

    // ------------------------------------------------------------------ F2: wrong action / bad proof
    function test_F2_wrongActionReverts() public {
        Run memory r = _find(false);
        AlephFlappy.AiPly[] memory plies = _plies(r);
        bytes memory bad = bytes.concat(r.actions);
        bad[2] = bytes1(uint8(bad[2]) ^ 8); // tick 19
        vm.prank(r.player);
        vm.expectRevert(abi.encodeWithSelector(AlephFlappy.WrongAction.selector, 19));
        game.settle(r.nonce, bad, plies);
    }

    function test_F2b_badProofReverts() public {
        Run memory r = _find(false);
        AlephFlappy.AiPly[] memory plies = _plies(r);
        plies[5].y = hex"0300"; // not the circuit's output for x_5 -> registry rejects
        vm.prank(r.player);
        vm.expectRevert(MockAlephEval.InvalidProof.selector);
        game.settle(r.nonce, r.actions, plies);
        plies = _plies(r);
        mock.setReturnFalse(true);
        vm.prank(r.player);
        vm.expectRevert(abi.encodeWithSelector(AlephFlappy.ProofRejected.selector, 0));
        game.settle(r.nonce, r.actions, plies);
        assertFalse(game.settled(r.seed));
    }

    /// The pipes depend on the nonce: the record replayed under another nonce gets another seed and fails.
    function test_F2c_otherNonceGetsOtherPipes() public {
        Run memory r = _find(false);
        AlephFlappy.AiPly[] memory plies = _plies(r);
        assertTrue(game.seedOf(r.nonce + 1) != r.seed);
        vm.prank(r.player);
        vm.expectRevert(); // a screen the mock never saw: InvalidProof
        game.settle(r.nonce + 1, r.actions, plies);
    }

    /// A seed is global. A run flown by one address (a guest) settles from any other, which gets the credit;
    /// after that nobody can settle the seed again, the original player included.
    function test_F2d_anyAddressSettlesOnceGlobally() public {
        Run memory r = _find(false);
        AlephFlappy.AiPly[] memory plies = _plies(r);
        address wallet = address(0xBEEF);
        vm.expectEmit(true, true, false, true, address(game));
        emit AlephFlappy.RunSettled(wallet, r.seed, uint8(r.score), uint8(r.ticks));
        vm.prank(wallet);
        game.settle(r.nonce, r.actions, plies);
        assertEq(game.bestScore(wallet), r.score);
        assertEq(game.bestScore(r.player), 0);
        vm.prank(r.player);
        vm.expectRevert(AlephFlappy.AlreadySettled.selector);
        game.settle(r.nonce, r.actions, plies);
        vm.prank(address(0xdEaD));
        vm.expectRevert(AlephFlappy.AlreadySettled.selector);
        game.settle(r.nonce, r.actions, plies);
    }

    /// Seed = keccak256(abi.encode(keccak256("AlephTape.flappy.v2"), nonce)); golden values shared with Python / TS.
    function test_F2e_seedDomain() public view {
        assertEq(game.SEED_DOMAIN(), 0x1bb23192f745fb5aeef19ba83b43035941bdf855b4e85be28d0ddb6bcc0b8990);
        assertEq(game.seedOf(7), 0x44aadd782a8820144eb679dc9f96ffd6850e677acb3b7444e9622c2d6dfda556);
        assertEq(game.seedOf(7), keccak256(abi.encode(keccak256("AlephTape.flappy.v2"), uint256(7))));
    }

    // ------------------------------------------------------------------ F3: encodings
    function test_F3_badTicksAndActions() public {
        Run memory r = _find(true);
        AlephFlappy.AiPly[] memory plies = _plies(r);
        vm.startPrank(r.player);
        vm.expectRevert(AlephFlappy.BadTicks.selector);
        game.settle(r.nonce, "", new AlephFlappy.AiPly[](0));
        vm.expectRevert(AlephFlappy.BadTicks.selector);
        game.settle(r.nonce, new bytes(5), new AlephFlappy.AiPly[](33));
        vm.expectRevert(AlephFlappy.BadActions.selector);
        game.settle(r.nonce, bytes.concat(r.actions, hex"00"), plies); // one byte too many
        if (r.ticks % 8 != 0) {
            bytes memory pad = bytes.concat(r.actions);
            pad[pad.length - 1] = bytes1(uint8(pad[pad.length - 1]) | 0x80); // a non-zero padding bit
            vm.expectRevert(AlephFlappy.BadActions.selector);
            game.settle(r.nonce, pad, plies);
        }
        vm.stopPrank();
    }

    function test_F3b_decide() public {
        assertTrue(game.decide(hex"8000")); // s_noflap 0, s_flap 1
        assertFalse(game.decide(hex"0100")); // 1 : 0
        assertFalse(game.decide(hex"8100")); // tie 1 : 1 -> no flap
        assertTrue(game.decide(hex"0001")); // s_flap = 2 (bit 8)
        assertFalse(game.decide(hex"7f3f")); // 127 : 126
        assertFalse(game.decide(hex"7e3f")); // 126 : 126 tie
        assertTrue(game.decide(hex"7d3f")); // 125 : 126
        vm.expectRevert(AlephFlappy.BadInput.selector);
        game.decide(hex"00");
        vm.expectRevert(AlephFlappy.BadInput.selector);
        game.screen(bytes32(0), 32, 3);
    }

    // ------------------------------------------------------------------ F4: cached screens skip verify
    function test_F4_cachedSkipsVerify() public {
        Run memory r = _find(false);
        AlephFlappy.AiPly[] memory plies = _plies(r);
        for (uint256 t; t < 10; ++t) {
            mock.setCached(r.xs[t], plies[t].y);
            plies[t].y = "";
        }
        uint256 cachedDistinct;
        for (uint256 t; t < 10; ++t) {
            bool seen;
            for (uint256 u; u < t && !seen; ++u) {
                seen = keccak256(r.xs[u]) == keccak256(r.xs[t]);
            }
            if (!seen) ++cachedDistinct;
        }
        vm.prank(r.player);
        game.settle(r.nonce, r.actions, plies);
        assertEq(mock.verifyCalls(), _distinct(r) - cachedDistinct);
    }

    function test_F4b_missingProofReverts() public {
        Run memory r = _find(false);
        AlephFlappy.AiPly[] memory plies = _plies(r);
        plies[7].y = "";
        vm.prank(r.player);
        vm.expectRevert(abi.encodeWithSelector(AlephFlappy.MissingProof.selector, 7));
        game.settle(r.nonce, r.actions, plies);
    }

    // ------------------------------------------------------------------ F5: each seed once
    function test_F5_alreadySettled() public {
        Run memory r = _find(false);
        AlephFlappy.AiPly[] memory plies = _plies(r);
        vm.prank(r.player);
        game.settle(r.nonce, r.actions, plies);
        vm.prank(r.player);
        vm.expectRevert(AlephFlappy.AlreadySettled.selector);
        game.settle(r.nonce, r.actions, plies);
    }

    // ------------------------------------------------------------------ F6: run must end by crash or at N_MAX
    function test_F6_notFinished() public {
        Run memory r = _find(false);
        AlephFlappy.AiPly[] memory full = _plies(r);
        AlephFlappy.AiPly[] memory plies = new AlephFlappy.AiPly[](24);
        for (uint256 t; t < 24; ++t) {
            plies[t] = full[t];
        }
        bytes memory acts = new bytes(3);
        for (uint256 i; i < 3; ++i) {
            acts[i] = r.actions[i];
        }
        vm.prank(r.player);
        vm.expectRevert(AlephFlappy.NotFinished.selector);
        game.settle(r.nonce, acts, plies);
    }

    function test_F6b_ticksAfterCrash() public {
        Run memory r = _find(true);
        AlephFlappy.AiPly[] memory full = _plies(r);
        AlephFlappy.AiPly[] memory plies = new AlephFlappy.AiPly[](r.ticks + 1);
        for (uint256 t; t < r.ticks; ++t) {
            plies[t] = full[t];
        }
        bytes memory acts = new bytes((r.ticks + 8) / 8);
        for (uint256 i; i < r.actions.length; ++i) {
            acts[i] = r.actions[i];
        }
        vm.prank(r.player);
        vm.expectRevert(abi.encodeWithSelector(AlephFlappy.TicksAfterCrash.selector, r.ticks));
        game.settle(r.nonce, acts, plies);
    }

    // ------------------------------------------------------------------ F7: gas with the real registry
    /// Gas a GasBurnVerifier burns per call: FlappyGroth16Verifier.verifyProof (test_realProofRun logs it).
    uint256 constant VERIFIER_BURN = 210_000;

    function _realRegistry(address verifier) internal returns (AlephRegistry reg, bytes32 key) {
        MockFactory factory = new MockFactory();
        MockProcessor proc = new MockProcessor(address(factory));
        factory.setCPU(address(proc), true);
        proc.put(53, hex"02abababababababababababababababababababababab", 64, 14);
        reg = new AlephRegistry(address(factory));
        reg.allowProcessor(address(proc));
        key = reg.register(address(proc), 53, new AlephRegistry.CircuitRef[](0), verifier);
    }

    function _cleanPlies(Run memory r) internal pure returns (AlephFlappy.AiPly[] memory plies) {
        plies = new AlephFlappy.AiPly[](r.ticks);
        for (uint256 t; t < r.ticks; ++t) {
            plies[t].y = _y(_act(r.actions, t));
        }
    }

    function test_F7_fullSprintGas() public {
        (AlephRegistry reg, bytes32 key) = _realRegistry(address(new GasBurnVerifier(VERIFIER_BURN)));
        assertEq(reg.circuit(key).nPub, 2);
        AlephFlappy g = new AlephFlappy(address(reg), key);
        Run memory r = _find(false);
        AlephFlappy.AiPly[] memory plies = _cleanPlies(r);
        uint256 nv = _distinct(r);
        uint256 gasLimit = g.GAS_PER_PROOF() * nv + g.GAS_BASE(); // documented formula: distinct uncached screens
        vm.prank(r.player);
        uint256 before = gasleft();
        g.settle{gas: gasLimit}(r.nonce, r.actions, plies);
        uint256 used = before - gasleft();
        emit log_named_uint("settle gas, 32 ticks, distinct screens verified (verifier burns 210k each)", used);
        emit log_named_uint("distinct screens verified", nv);
        emit log_named_uint("per verified screen (avg)", used / nv);
        assertLt(used, gasLimit);
        // the same screens in another run are now cached: no proofs at all
        (bool proven,) = reg.getResult(key, r.xs[0]);
        assertTrue(proven);
    }

    function test_F7b_cachedSprintGas() public {
        (AlephRegistry reg, bytes32 key) = _realRegistry(address(new GasBurnVerifier(VERIFIER_BURN)));
        AlephFlappy g = new AlephFlappy(address(reg), key);
        Run memory r = _find(false);
        AlephFlappy.AiPly[] memory plies = _cleanPlies(r);
        for (uint256 t; t < 32; ++t) {
            (bool p,) = reg.getResult(key, r.xs[t]);
            if (!p) reg.verifyEval(key, r.xs[t], plies[t].y, plies[t].proof);
        }
        AlephFlappy.AiPly[] memory empty = new AlephFlappy.AiPly[](32);
        uint256 gasLimit = g.GAS_BASE(); // documented formula with 0 screens to verify
        vm.prank(r.player);
        uint256 before = gasleft();
        g.settle{gas: gasLimit}(r.nonce, r.actions, empty);
        emit log_named_uint("settle gas, 32 ticks all cached", before - gasleft());
    }

    function test_F7c_tooLittleGasReverts() public {
        (AlephRegistry reg, bytes32 key) = _realRegistry(address(new GasBurnVerifier(VERIFIER_BURN)));
        AlephFlappy g = new AlephFlappy(address(reg), key);
        Run memory r = _find(false);
        AlephFlappy.AiPly[] memory plies = _cleanPlies(r);
        vm.prank(r.player);
        vm.expectRevert(AlephRegistry.InsufficientGas.selector);
        g.settle{gas: 3_000_000}(r.nonce, r.actions, plies);
    }

    // ------------------------------------------------------------------ reference vectors (circuit output -> action)
    struct FlappyVec {
        uint256 flap;
        bytes x;
        bytes y;
    }

    /// circuits/flappy/vectors.json: [{x: 8 bytes, y: 2 bytes (the real circuit output), flap: 0|1}].
    function test_referenceVectors() public view {
        string memory j = vm.readFile(string.concat(vm.projectRoot(), "/../circuits/flappy/vectors.json"));
        FlappyVec[] memory v =
            abi.decode(vm.parseJsonTypeArray(j, "$", "FlappyVec(uint256 flap,bytes x,bytes y)"), (FlappyVec[]));
        assertEq(v.length, 1000);
        for (uint256 i; i < v.length; ++i) {
            assertEq(game.decide(v[i].y), v[i].flap == 1, string.concat("vector ", vm.toString(i)));
        }
    }

    // ------------------------------------------------------------------ real proofs
    /// test/fixtures/flappy_proofs.json: one full BNN sprint, every tick proven with the real FlappyGroth16Verifier.
    function _fixturePlies(string memory fx, uint256 n) internal view returns (AlephFlappy.AiPly[] memory plies) {
        plies = new AlephFlappy.AiPly[](n);
        for (uint256 t; t < n; ++t) {
            string memory p = string.concat(".cases[", vm.toString(t), "]");
            plies[t].y = fx.readBytes(string.concat(p, ".yHex"));
            bytes32[] memory w = fx.readBytes32Array(string.concat(p, ".proof"));
            for (uint256 k; k < 24; ++k) {
                plies[t].proof[k] = uint256(w[k]);
            }
        }
    }

    function test_realProofRun() public {
        string memory fx = vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/flappy_proofs.json"));
        address verifier = vm.deployCode("FlappyGroth16Verifier.sol:FlappyGroth16Verifier");
        (AlephRegistry reg, bytes32 key) = _realRegistry(verifier);
        AlephFlappy g = new AlephFlappy(address(reg), key);
        AlephFlappy.AiPly[] memory plies = _fixturePlies(fx, fx.readUint(".ticks"));
        uint256 used = _settleFixture(g, fx, plies);
        emit log_named_uint("real-proof sprint ticks", plies.length);
        emit log_named_uint("real-proof distinct screens verified", fx.readUint(".verified"));
        emit log_named_uint("real-proof settle gas", used);
        emit log_named_uint("real-proof gas per verified screen", used / fx.readUint(".verified"));
        _logVerifierGas(verifier, fx, plies[0].proof);
    }

    function _settleFixture(AlephFlappy g, string memory fx, AlephFlappy.AiPly[] memory plies)
        internal
        returns (uint256 used)
    {
        bytes memory actions = fx.readBytes(".actions");
        uint256 nonce = fx.readUint(".nonce");
        uint256 gasLimit = g.GAS_PER_PROOF() * fx.readUint(".verified") + g.GAS_BASE();
        vm.prank(address(0xBEEF)); // any address: the seed is bound to none
        uint256 before = gasleft();
        (uint8 score, uint8 ticks) = g.settle{gas: gasLimit}(nonce, actions, plies);
        used = before - gasleft();
        assertEq(score, fx.readUint(".score"));
        assertEq(ticks, plies.length);
    }

    function _logVerifierGas(address verifier, string memory fx, uint256[24] memory proof) internal {
        uint256[] memory pv = fx.readUintArray(".cases[0].pub");
        uint256[2] memory pub = [pv[0], pv[1]];
        uint256 g0 = gasleft();
        (bool ok, bytes memory ret) =
            verifier.staticcall(abi.encodeWithSignature("verifyProof(uint256[24],uint256[2])", proof, pub));
        uint256 used = g0 - gasleft();
        assertTrue(ok && abi.decode(ret, (bool)), "real proof must verify");
        emit log_named_uint("FlappyGroth16Verifier.verifyProof gas (warm address)", used);
        assertLt(used, VERIFIER_BURN + 10_000);
    }
}
