// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {AlephGame2048} from "../src/AlephGame2048.sol";
import {AlephRegistry} from "../src/AlephRegistry.sol";
import {MockFactory, MockProcessor} from "./mocks/MockTapeOut.sol";
import {MockAlephEval, GasBurnVerifier} from "./mocks/MockAlephEval.sol";

/// Spec T1–T8. Runs come from test/fixtures/game2048_runs.json, written by the
/// independent Python reference: seed, initial board, every
/// board before a move, its x, the moves, score, max tile and the final board. Scripted plies get a crafted y with
/// the top score on the script's direction (the mock registry's "truth"), so the selection must agree.
contract AlephGame2048Test is Test {
    using stdJson for string;

    bytes32 constant KEY = keccak256("game2048");
    uint256 constant S = 6; // score bits (H = 48)
    uint256 constant Y_BYTES = 3; // ceil(4 * 6 / 8)
    uint256 constant N_MAX = 64;
    MockAlephEval mock;
    AlephGame2048 game;
    string runs;
    /// Seeds are bound to no address: the tests settle as this player unless they say otherwise.
    address player = address(0xA1E9A);

    function setUp() public {
        mock = new MockAlephEval();
        game = new AlephGame2048(address(mock), KEY, S, N_MAX);
        runs = vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/game2048_runs.json"));
    }

    // ------------------------------------------------------------------ helpers
    function _run(string memory name)
        internal
        view
        returns (uint256 nonce, bytes memory moves, bytes[] memory xs, uint256 score, uint256 maxTile)
    {
        string memory p = string.concat(".", name);
        nonce = runs.readUint(string.concat(p, ".nonce"));
        moves = runs.readBytes(string.concat(p, ".moves"));
        xs = runs.readBytesArray(string.concat(p, ".xs"));
        score = runs.readUint(string.concat(p, ".score"));
        maxTile = runs.readUint(string.concat(p, ".maxTile"));
    }

    function _y(uint256 dir) internal pure returns (bytes memory y) {
        y = new bytes(Y_BYTES);
        _setScore(y, dir, (1 << S) - 1);
    }

    function _setScore(bytes memory y, uint256 dir, uint256 score) internal pure {
        for (uint256 b; b < S; ++b) {
            uint256 i = dir * S + b;
            uint8 cur = uint8(y[i / 8]);
            uint8 m = uint8(1 << (i % 8));
            y[i / 8] = bytes1(((score >> b) & 1) == 1 ? cur | m : cur & ~m);
        }
    }

    /// Plies whose y points at the recorded move; mock truth = that y, so verifyEval accepts it.
    function _plies(bytes memory moves, bytes[] memory xs) internal returns (AlephGame2048.AiPly[] memory plies) {
        plies = new AlephGame2048.AiPly[](moves.length);
        for (uint256 i; i < moves.length; ++i) {
            bytes memory y = _y(uint8(moves[i]));
            mock.setTruth(xs[i], y);
            plies[i].y = y;
        }
    }

    function _prefix(bytes memory b, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = b[i];
        }
    }

    // ------------------------------------------------------------------ Python == Solidity: seed, spawns, rules, x
    function test_rulesMatchPythonReference() public view {
        string[2] memory names = ["full", "death"];
        for (uint256 k; k < 2; ++k) {
            string memory p = string.concat(".", names[k]);
            (uint256 nonce, bytes memory moves, bytes[] memory xs, uint256 score,) = _run(names[k]);
            bytes32 seed = game.seedOf(nonce);
            assertEq(seed, runs.readBytes32(string.concat(p, ".seed")), "seed");
            assertEq(game.initialBoard(seed), runs.readUint(string.concat(p, ".initial")), "initial board");
            uint256[] memory boards = runs.readUintArray(string.concat(p, ".boards"));
            for (uint256 i; i < moves.length; ++i) {
                (uint64 b,,) = game.play(seed, _prefix(moves, i));
                assertEq(b, boards[i], string.concat(names[k], " board before move ", vm.toString(i)));
                assertEq(game.encodeX(b), xs[i], "x");
            }
            (uint64 fin, uint256 sc, uint8 legal) = game.play(seed, moves);
            assertEq(fin, runs.readUint(string.concat(p, ".final")), "final board");
            assertEq(sc, score, "score");
            assertEq(legal == 0, k == 1, "only the death run ends without a legal move");
        }
    }

    function test_moveBasics() public view {
        // row 0: 2 2 4 4 (exponents 1 1 2 2) -> Left: 4 8 . . (+4 +8); Right: . . 4 8
        uint64 b = 0x2211;
        (uint64 l, uint256 gl, bool cl) = game.move(b, 3);
        assertEq(l, 0x32);
        assertEq(gl, 12);
        assertTrue(cl);
        (uint64 r,,) = game.move(b, 1);
        assertEq(r, 0x3200);
        // column 0: 2 . 2 2 (cells 0, 8, 12) -> Up: 4 2 . . (merge nearest the edge first)
        uint64 c = uint64(0x1) | (uint64(0x1) << 32) | (uint64(0x1) << 48);
        (uint64 u, uint256 gu,) = game.move(c, 0);
        assertEq(u, uint64(0x2) | (uint64(0x1) << 16));
        assertEq(gu, 4);
        (uint64 d,,) = game.move(c, 2);
        assertEq(d, (uint64(0x1) << 32) | (uint64(0x2) << 48));
        // 2 2 2 2 -> 4 4 . . ; a merged tile does not merge again
        (uint64 m,,) = game.move(0x1111, 3);
        assertEq(m, 0x22);
        // nothing moves -> illegal
        (,, bool ch) = game.move(0x21, 3);
        assertFalse(ch);
    }

    /// The bit-trick legality mask == "the move changes the board", on boards with exponents 0..11.
    function testFuzz_legalMaskEqualsMoveChanges(uint256 seed) public view {
        uint64 b;
        for (uint256 i; i < 16; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 e = r % 3 == 0 ? 0 : (r >> 8) % 12; // ~1/3 + empties, small exponents collide often
            if ((r >> 16) % 2 == 0 && e > 3) e = e % 4;
            b |= uint64(e) << uint64(4 * i);
        }
        uint8 mask = game.legalMask(b);
        for (uint8 d; d < 4; ++d) {
            (,, bool changed) = game.move(b, d);
            assertEq((mask >> d) & 1 == 1, changed);
        }
    }

    // ------------------------------------------------------------------ T1: a correct run settles
    function test_T1_fullRunSettles() public {
        (uint256 nonce, bytes memory moves, bytes[] memory xs, uint256 score, uint256 maxTile) = _run("full");
        assertEq(moves.length, N_MAX);
        AlephGame2048.AiPly[] memory plies = _plies(moves, xs);
        bytes32 seed = game.seedOf(nonce);
        vm.expectEmit(true, true, false, true, address(game));
        emit AlephGame2048.RunSettled(player, seed, score, maxTile, uint16(N_MAX));
        vm.prank(player);
        assertEq(game.settle(nonce, moves, plies), score);
        assertEq(game.bestScore(player), score);
        assertTrue(game.settled(seed));
        assertEq(mock.verifyCalls(), N_MAX);
        assertEq(mock.lastKey(), KEY);
        assertEq(game.registry(), address(mock));
        assertEq(game.circuitKey(), KEY);
        assertEq(game.nMax(), N_MAX);
        assertEq(game.scoreBits(), S);
    }

    function test_T1b_runEndsWhenNoMoveIsLegal() public {
        (uint256 nonce, bytes memory moves, bytes[] memory xs, uint256 score, uint256 maxTile) = _run("death");
        assertLt(moves.length, N_MAX);
        AlephGame2048.AiPly[] memory plies = _plies(moves, xs);
        vm.expectEmit(true, true, false, true, address(game));
        emit AlephGame2048.RunSettled(player, game.seedOf(nonce), score, maxTile, uint16(moves.length));
        vm.prank(player);
        assertEq(game.settle(nonce, moves, plies), score);
    }

    function test_T1c_bestScoreKeepsTheMax() public {
        (uint256 n1, bytes memory m1, bytes[] memory x1, uint256 s1,) = _run("full");
        (uint256 n2, bytes memory m2, bytes[] memory x2, uint256 s2,) = _run("death");
        assertGt(s1, s2);
        AlephGame2048.AiPly[] memory p1 = _plies(m1, x1);
        AlephGame2048.AiPly[] memory p2 = _plies(m2, x2);
        vm.startPrank(player);
        game.settle(n1, m1, p1);
        game.settle(n2, m2, p2);
        vm.stopPrank();
        assertEq(game.bestScore(player), s1);
    }

    // ------------------------------------------------------------------ T2: wrong move / bad proof
    function test_T2_wrongMoveReverts() public {
        (uint256 nonce, bytes memory moves, bytes[] memory xs,,) = _run("full");
        AlephGame2048.AiPly[] memory plies = _plies(moves, xs);
        moves[10] = bytes1((uint8(moves[10]) + 1) % 4);
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(AlephGame2048.WrongMove.selector, 10));
        game.settle(nonce, moves, plies);
        moves[10] = 0x07;
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(AlephGame2048.WrongMove.selector, 10));
        game.settle(nonce, moves, plies);
    }

    function test_T2b_scoresThatPickAnotherDirectionAreRejected() public {
        (uint256 nonce, bytes memory moves, bytes[] memory xs,,) = _run("full");
        AlephGame2048.AiPly[] memory plies = _plies(moves, xs);
        plies[5].y = _y((uint8(moves[5]) + 2) % 4); // not what the circuit outputs for x[5]
        vm.prank(player);
        vm.expectRevert(MockAlephEval.InvalidProof.selector);
        game.settle(nonce, moves, plies);
    }

    function test_T2c_registryFalseReverts() public {
        (uint256 nonce, bytes memory moves, bytes[] memory xs,,) = _run("full");
        AlephGame2048.AiPly[] memory plies = _plies(moves, xs);
        mock.setReturnFalse(true);
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(AlephGame2048.ProofRejected.selector, 0));
        game.settle(nonce, moves, plies);
    }

    function test_T2d_anotherNonceCannotReuseTheRun() public {
        (uint256 nonce, bytes memory moves, bytes[] memory xs,,) = _run("full");
        AlephGame2048.AiPly[] memory plies = _plies(moves, xs);
        vm.prank(player);
        vm.expectRevert(); // other seed -> other spawns -> the scripted moves stop matching (or a proof is missing)
        game.settle(nonce + 1, moves, plies);
    }

    // ------------------------------------------------------------------ T3: illegal / too long / unfinished
    function test_T3_tooManyMoves() public {
        AlephGame2048.AiPly[] memory plies = new AlephGame2048.AiPly[](N_MAX + 1);
        vm.expectRevert(AlephGame2048.TooManyMoves.selector);
        game.settle(1, new bytes(N_MAX + 1), plies);
    }

    function test_T3b_plyCount() public {
        (uint256 nonce, bytes memory moves,,,) = _run("full");
        vm.prank(player);
        vm.expectRevert(AlephGame2048.PlyCount.selector);
        game.settle(nonce, moves, new AlephGame2048.AiPly[](moves.length - 1));
    }

    function test_T3c_notFinished() public {
        (uint256 nonce, bytes memory moves, bytes[] memory xs,,) = _run("full");
        AlephGame2048.AiPly[] memory plies = _plies(moves, xs);
        bytes memory short = _prefix(moves, N_MAX - 1);
        AlephGame2048.AiPly[] memory sp = new AlephGame2048.AiPly[](N_MAX - 1);
        for (uint256 i; i < sp.length; ++i) {
            sp[i] = plies[i];
        }
        vm.prank(player);
        vm.expectRevert(AlephGame2048.NotFinished.selector);
        game.settle(nonce, short, sp);
    }

    function test_T3d_movesAfterEnd() public {
        (uint256 nonce, bytes memory moves, bytes[] memory xs,,) = _run("death");
        AlephGame2048.AiPly[] memory plies = _plies(moves, xs);
        bytes memory longer = bytes.concat(moves, hex"00");
        AlephGame2048.AiPly[] memory lp = new AlephGame2048.AiPly[](moves.length + 1);
        for (uint256 i; i < plies.length; ++i) {
            lp[i] = plies[i];
        }
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(AlephGame2048.MovesAfterEnd.selector, moves.length));
        game.settle(nonce, longer, lp);
    }

    function test_T3e_playRejectsIllegalMoves() public {
        bytes32 seed = game.seedOf(1);
        uint64 b = game.initialBoard(seed);
        for (uint8 d; d < 4; ++d) {
            (,, bool changed) = game.move(b, d);
            if (!changed) {
                vm.expectRevert(abi.encodeWithSelector(AlephGame2048.MovesAfterEnd.selector, 0));
                game.play(seed, abi.encodePacked(d));
            }
        }
        vm.expectRevert(abi.encodeWithSelector(AlephGame2048.MovesAfterEnd.selector, 0));
        game.play(seed, hex"04");
    }

    // ------------------------------------------------------------------ T4: cached boards skip the verifier
    function test_T4_cachedSkipsVerify() public {
        (uint256 nonce, bytes memory moves, bytes[] memory xs, uint256 score,) = _run("full");
        for (uint256 i; i < moves.length; ++i) {
            mock.setCached(xs[i], _y(uint8(moves[i])));
        }
        vm.prank(player);
        assertEq(game.settle(nonce, moves, new AlephGame2048.AiPly[](moves.length)), score);
        assertEq(mock.verifyCalls(), 0);
    }

    function test_T4b_missingProofReverts() public {
        (uint256 nonce, bytes memory moves,,,) = _run("full");
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(AlephGame2048.MissingProof.selector, 0));
        game.settle(nonce, moves, new AlephGame2048.AiPly[](moves.length));
    }

    // ------------------------------------------------------------------ T5: each seed once
    function test_T5_alreadySettled() public {
        (uint256 nonce, bytes memory moves, bytes[] memory xs,,) = _run("full");
        AlephGame2048.AiPly[] memory plies = _plies(moves, xs);
        vm.startPrank(player);
        game.settle(nonce, moves, plies);
        vm.expectRevert(AlephGame2048.AlreadySettled.selector);
        game.settle(nonce, moves, plies);
        vm.stopPrank();
    }

    /// A seed is global. A run "played" by one address (a guest) settles from any other, which gets the credit;
    /// after that nobody can settle the seed again, the original player included.
    function test_T5b_anyAddressSettlesOnceGlobally() public {
        (uint256 nonce, bytes memory moves, bytes[] memory xs, uint256 score, uint256 maxTile) = _run("full");
        AlephGame2048.AiPly[] memory plies = _plies(moves, xs);
        address wallet = address(0xBEEF);
        vm.expectEmit(true, true, false, true, address(game));
        emit AlephGame2048.RunSettled(wallet, game.seedOf(nonce), score, maxTile, uint16(moves.length));
        vm.prank(wallet);
        assertEq(game.settle(nonce, moves, plies), score);
        assertEq(game.bestScore(wallet), score);
        assertEq(game.bestScore(player), 0);
        vm.prank(player);
        vm.expectRevert(AlephGame2048.AlreadySettled.selector);
        game.settle(nonce, moves, plies);
        vm.prank(address(0xdEaD));
        vm.expectRevert(AlephGame2048.AlreadySettled.selector);
        game.settle(nonce, moves, plies);
    }

    /// Seed = keccak256(abi.encode(keccak256("AlephTape.game2048.v2"), nonce)); golden values shared with Python / TS.
    function test_T5c_seedDomain() public view {
        assertEq(game.SEED_DOMAIN(), 0xa9e8b925451706198b79cddf96db42630a192b0c9b8b8bae026b261e1ab02300);
        assertEq(game.seedOf(7), 0x86b102dad5669ad45ad74cc0d6830d0996c1e6023b4df69d22839e71c416650a);
        assertEq(game.seedOf(7), keccak256(abi.encode(keccak256("AlephTape.game2048.v2"), uint256(7))));
    }

    // ------------------------------------------------------------------ T6: selection rule
    function _board(uint8[16] memory e) internal pure returns (uint64 b) {
        for (uint256 i; i < 16; ++i) {
            b |= uint64(e[i]) << uint64(4 * i);
        }
    }

    function test_T6_selectIgnoresIllegalAndBreaksTiesLow() public view {
        // only Down and Right are legal: tiles in the top-left corner, row 0 = 2 4, nothing to merge up/left
        uint8[16] memory e;
        e[0] = 1;
        e[1] = 2;
        bytes memory x = game.encodeX(_board(e));
        bytes memory y = new bytes(Y_BYTES);
        _setScore(y, 0, 63); // Up: illegal
        _setScore(y, 3, 63); // Left: illegal
        _setScore(y, 1, 10);
        _setScore(y, 2, 10);
        assertEq(game.select(x, y), 1, "tie between legal R and D -> R");
        _setScore(y, 2, 11);
        assertEq(game.select(x, y), 2);
        assertEq(game.select(x, new bytes(Y_BYTES)), 1, "all zero -> lowest legal");
        // every direction legal on a lone middle tile: ties -> Up
        uint8[16] memory f;
        f[5] = 3;
        assertEq(game.select(game.encodeX(_board(f)), new bytes(Y_BYTES)), 0);
        bytes memory y2 = new bytes(Y_BYTES);
        _setScore(y2, 3, 1);
        assertEq(game.select(game.encodeX(_board(f)), y2), 3, "score decode at the last direction");
    }

    function test_T6b_selectRejectsBadInput() public {
        vm.expectRevert(AlephGame2048.BadInput.selector);
        game.select(new bytes(24), new bytes(Y_BYTES)); // not one-hot
        uint8[16] memory e;
        e[5] = 1;
        bytes memory x = game.encodeX(_board(e));
        vm.expectRevert(AlephGame2048.BadInput.selector);
        game.select(x, new bytes(Y_BYTES + 1));
        vm.expectRevert(AlephGame2048.BadInput.selector);
        game.select(new bytes(23), new bytes(Y_BYTES));
        // a full board with no merge: no legal direction
        uint8[16] memory g;
        for (uint256 i; i < 16; ++i) {
            g[i] = uint8(1 + ((i + i / 4) % 2));
        }
        bytes memory full = game.encodeX(_board(g));
        vm.expectRevert(AlephGame2048.BadInput.selector);
        game.select(full, new bytes(Y_BYTES));
    }

    function test_T6c_encodeXMatchesSpec() public view {
        uint8[16] memory e;
        e[0] = 1; // bit 1
        e[15] = 11; // bit 12*15 + 11 = 191 -> byte 23, bit 7
        bytes memory x = game.encodeX(_board(e));
        assertEq(x.length, 24);
        assertEq(uint8(x[0]), 0x02 | 0x00);
        assertEq(uint8(x[23]), 0x80);
        assertEq(uint8(x[1]), 0x10); // cell 1 empty: bit 12 -> byte 1, bit 4
        e[15] = 13; // saturates at level 11
        assertEq(game.encodeX(_board(e)), x);
    }

    // ------------------------------------------------------------------ T7: gas, real registry, ~210k verifier
    uint256 constant VERIFIER_BURN = 210_000;
    // documented formula: 300k x moves to verify + 30k x moves + 600k
    uint256 constant GAS_PER_PLY = 300_000;
    uint256 constant GAS_PER_MOVE = 30_000;
    uint256 constant GAS_BASE = 600_000;

    function _gasLimit(uint256 toVerify, uint256 nMoves) internal pure returns (uint256) {
        return GAS_PER_PLY * toVerify + GAS_PER_MOVE * nMoves + GAS_BASE;
    }

    function _realRegistry(address verifier) internal returns (AlephRegistry reg, bytes32 key) {
        MockFactory factory = new MockFactory();
        MockProcessor proc = new MockProcessor(address(factory));
        factory.setCPU(address(proc), true);
        proc.put(36, hex"02abababababababababababababababababababababab", 192, uint32(4 * S));
        reg = new AlephRegistry(address(factory));
        reg.allowProcessor(address(proc));
        key = reg.register(address(proc), 36, new AlephRegistry.CircuitRef[](0), verifier);
    }

    function _craftedPlies(bytes memory moves) internal pure returns (AlephGame2048.AiPly[] memory plies) {
        plies = new AlephGame2048.AiPly[](moves.length);
        for (uint256 i; i < moves.length; ++i) {
            plies[i].y = _y(uint8(moves[i]));
        }
    }

    function test_T7_fullRunGas() public {
        (AlephRegistry reg, bytes32 key) = _realRegistry(address(new GasBurnVerifier(VERIFIER_BURN)));
        assertEq(reg.circuit(key).nPub, 2);
        AlephGame2048 g = new AlephGame2048(address(reg), key, S, N_MAX);
        (uint256 nonce, bytes memory moves, bytes[] memory xs, uint256 score,) = _run("full");
        AlephGame2048.AiPly[] memory plies = _craftedPlies(moves);
        uint256 gasLimit = _gasLimit(N_MAX, N_MAX);
        vm.prank(player);
        uint256 before = gasleft();
        assertEq(g.settle{gas: gasLimit}(nonce, moves, plies), score);
        uint256 used = before - gasleft();
        emit log_named_uint("settle gas, 64 moves all verified (verifier burns 210k each)", used);
        emit log_named_uint("per verified move (avg)", used / N_MAX);
        emit log_named_uint("gas limit by formula", gasLimit);
        assertLt(used, gasLimit);
        assertLt(gasLimit, 50_000_000);
        (bool proven,) = reg.getResult(key, xs[0]);
        assertTrue(proven);
    }

    function test_T7b_cachedRunGas() public {
        (AlephRegistry reg, bytes32 key) = _realRegistry(address(new GasBurnVerifier(VERIFIER_BURN)));
        AlephGame2048 g = new AlephGame2048(address(reg), key, S, N_MAX);
        (uint256 nonce, bytes memory moves, bytes[] memory xs,,) = _run("full");
        AlephGame2048.AiPly[] memory plies = _craftedPlies(moves);
        for (uint256 i; i < moves.length; ++i) {
            reg.verifyEval(key, xs[i], plies[i].y, plies[i].proof);
        }
        vm.prank(player);
        uint256 before = gasleft();
        g.settle{gas: _gasLimit(0, N_MAX)}(nonce, moves, new AlephGame2048.AiPly[](moves.length));
        emit log_named_uint("settle gas, 64 moves all cached (pure replay + 64 registry reads)", before - gasleft());
    }

    function test_T7c_tooLittleGasReverts() public {
        (AlephRegistry reg, bytes32 key) = _realRegistry(address(new GasBurnVerifier(VERIFIER_BURN)));
        AlephGame2048 g = new AlephGame2048(address(reg), key, S, N_MAX);
        (uint256 nonce, bytes memory moves,,,) = _run("full");
        AlephGame2048.AiPly[] memory plies = _craftedPlies(moves);
        vm.prank(player);
        vm.expectRevert(AlephRegistry.InsufficientGas.selector);
        g.settle{gas: 250_000 * N_MAX}(nonce, moves, plies);
        vm.prank(player);
        g.settle{gas: _gasLimit(N_MAX, N_MAX)}(nonce, moves, plies);
    }

    // ------------------------------------------------------------------ reference vectors (Python / prover / web)
    struct Game2048Vec {
        uint256 move;
        bytes x;
        bytes y;
    }

    /// circuits/game2048/vectors.json: [{x: "0x..24B", y: "0x..", move}] — y is the real circuit output.
    function test_referenceVectors() public {
        string memory path = string.concat(vm.projectRoot(), "/../circuits/game2048/vectors.json");
        if (!vm.exists(path)) {
            vm.skip(true, "circuits/game2048/vectors.json not present yet");
            return;
        }
        Game2048Vec[] memory v = abi.decode(
            vm.parseJsonTypeArray(vm.readFile(path), "$", "Game2048Vec(uint256 move,bytes x,bytes y)"), (Game2048Vec[])
        );
        assertGt(v.length, 0);
        for (uint256 i; i < v.length; ++i) {
            assertEq(game.select(v[i].x, v[i].y), v[i].move, string.concat("vector ", vm.toString(i)));
        }
        emit log_named_uint("reference vectors matched", v.length);
    }

    // ------------------------------------------------------------------ real proofs (zk/fixture_game2048.py)
    /// test/fixtures/game2048_proofs.json: {nonce, moves, score, cases: [{xHex, yHex, pub, proof[24]}]}, one case
    /// per move; verified by the real Game2048Groth16Verifier behind the real AlephRegistry. Skipped if absent.
    function test_T8_realProofRun() public {
        string memory path = string.concat(vm.projectRoot(), "/test/fixtures/game2048_proofs.json");
        if (!vm.exists(path)) {
            vm.skip(true, "test/fixtures/game2048_proofs.json not present yet");
            return;
        }
        string memory fx = vm.readFile(path);
        address verifier = vm.deployCode("Game2048Groth16Verifier.sol:Game2048Groth16Verifier");
        (AlephRegistry reg, bytes32 key) = _realRegistry(verifier);
        AlephGame2048 g = new AlephGame2048(address(reg), key, fx.readUint(".scoreBits"), N_MAX);
        bytes memory moves = fx.readBytes(".moves");
        AlephGame2048.AiPly[] memory plies = _fixturePlies(fx, moves.length);
        // a flipped proof word is rejected by the real verifier (registry: InvalidProof)
        uint256 saved = plies[3].proof[0];
        plies[3].proof[0] = saved ^ 1;
        vm.expectRevert(AlephRegistry.InvalidProof.selector);
        this.settleAs(g, fx, moves, plies);
        plies[3].proof[0] = saved;

        (uint256 score, uint256 used) = this.settleAs(g, fx, moves, plies);
        assertEq(score, fx.readUint(".score"));
        emit log_named_uint("real-proof run moves", moves.length);
        emit log_named_uint("real-proof run score", score);
        emit log_named_uint("real-proof settle gas", used);
        _logVerifierGas(verifier, fx, plies[0].proof);
    }

    /// External so a revert inside can be expected; settles as 0xBEEF (any address) with the documented gas limit.
    function settleAs(AlephGame2048 g, string memory fx, bytes memory moves, AlephGame2048.AiPly[] memory plies)
        external
        returns (uint256 score, uint256 used)
    {
        uint256 nonce = fx.readUint(".nonce");
        vm.prank(address(0xBEEF));
        uint256 before = gasleft();
        score = g.settle{gas: _gasLimit(moves.length, moves.length)}(nonce, moves, plies);
        used = before - gasleft();
    }

    function _fixturePlies(string memory fx, uint256 n) internal view returns (AlephGame2048.AiPly[] memory plies) {
        plies = new AlephGame2048.AiPly[](n);
        for (uint256 i; i < n; ++i) {
            string memory p = string.concat(".cases[", vm.toString(i), "]");
            plies[i].y = fx.readBytes(string.concat(p, ".yHex"));
            bytes32[] memory w = fx.readBytes32Array(string.concat(p, ".proof"));
            for (uint256 k; k < 24; ++k) {
                plies[i].proof[k] = uint256(w[k]);
            }
        }
    }

    function _logVerifierGas(address verifier, string memory fx, uint256[24] memory proof) internal {
        uint256[] memory pv = fx.readUintArray(".cases[0].pub");
        uint256[2] memory pub = [pv[0], pv[1]];
        uint256 g0 = gasleft();
        (bool ok, bytes memory ret) =
            verifier.staticcall(abi.encodeWithSignature("verifyProof(uint256[24],uint256[2])", proof, pub));
        uint256 used = g0 - gasleft();
        assertTrue(ok && abi.decode(ret, (bool)), "real proof must verify");
        emit log_named_uint("Game2048Groth16Verifier.verifyProof gas (warm address)", used);
        assertLt(used, VERIFIER_BURN + 10_000);
    }
}
