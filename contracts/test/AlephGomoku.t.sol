// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {AlephGomoku} from "../src/AlephGomoku.sol";
import {AlephRegistry} from "../src/AlephRegistry.sol";
import {MockFactory, MockProcessor} from "./mocks/MockTapeOut.sol";
import {MockAlephEval, GasBurnVerifier} from "./mocks/MockAlephEval.sol";

/// Spec G1–G8. Games are scripted: every AI ply gets a crafted y with score 63
/// on the move the script wants, so the selection rule must agree (rules 1–4 override y). Scripts were checked
/// against an independent Python reference before being hardcoded. Rule plies (rules 1–4) never touch the
/// registry: SHORT/DIAG/ANTI/VERT have 4 proof plies + 2 rule plies, LONG 10 + 2.
contract AlephGomokuTest is Test {
    using stdJson for string;

    bytes32 constant KEY = keccak256("gomoku");
    MockAlephEval mock;
    AlephGomoku game;

    // human double-three fork at 41 (row 39-41 + column 23,32,41); AI blocks the column's open-four cell 14,
    // human makes an open four 38-41, AI blocks five-cell 37, human wins with 42
    bytes constant SHORT = hex"2750284817082000290e26252a";
    bytes constant AIWIN = hex"00480249044a064b144c"; // AI five on row 8 (72..76)
    // forks resolved on a diagonal / anti-diagonal / column five (AI blocks the lowest open-four cell each time)
    bytes constant DIAG = hex"14501e482a0829002827320a3c";
    bytes constant ANTI = hex"18502048260827002825301038";
    bytes constant VERT = hex"1f5031481e0832002814160d3a";
    bytes constant WRAPH = hex"0650074f084e094d0a"; // human 6,7,8,9,10 wraps a row: not a five
    bytes constant WRAPA = hex"0c50144f1c4e2c4d24"; // human 12,20,28,36,44 wraps ↙: not a five
    // 25 plies, 12 AI plies; six scattered human moves, then the SHORT fork
    bytes constant LONG = hex"0a501048400846000c4c44042724283e1712201a290e26252a";
    // 81 plies, tiling (c + 2r) % 4 < 2 = human: every 5-window holds both colours -> no win cell ever, draw
    bytes constant DRAW =
        hex"000201030406050708090b0a0c0d0f0e101112141315161817191a1b1d1c1e1f2120222324262527282a292b2c2d2f2e303133323435363837393a3c3b3d3e3f4140424345444647484a494b4c4e4d4f50";

    function setUp() public {
        mock = new MockAlephEval();
        game = new AlephGomoku(address(mock), KEY);
    }

    // ------------------------------------------------------------------ helpers (independent of the contract)
    function _x(bytes memory moves, uint256 upto) internal pure returns (bytes memory x) {
        x = new bytes(21);
        for (uint256 p; p < upto; ++p) {
            uint256 bit = uint8(moves[p]) + (p % 2 == 0 ? 81 : 0); // AI stones 0..80, human 81..161
            x[bit / 8] = bytes1(uint8(x[bit / 8]) | uint8(1 << (bit % 8)));
        }
    }

    function _y(uint256 cell, uint256 score) internal pure returns (bytes memory y) {
        y = new bytes(61);
        _setScore(y, cell, score);
    }

    function _setScore(bytes memory y, uint256 cell, uint256 score) internal pure {
        for (uint256 b; b < 6; ++b) {
            uint256 i = cell * 6 + b;
            uint8 cur = uint8(y[i / 8]);
            uint8 m = uint8(1 << (i % 8));
            y[i / 8] = bytes1(((score >> b) & 1) == 1 ? cur | m : cur & ~m);
        }
    }

    /// Plies whose y points at the recorded AI move; mock truth = that y, so verifyEval accepts it.
    function _plies(bytes memory moves) internal returns (AlephGomoku.AiPly[] memory plies) {
        plies = new AlephGomoku.AiPly[](moves.length / 2);
        for (uint256 j; j < plies.length; ++j) {
            uint256 p = 2 * j + 1;
            bytes memory x = _x(moves, p);
            bytes memory y = _y(uint8(moves[p]), 63);
            mock.setTruth(x, y);
            plies[j].y = y;
        }
    }

    function _bits(uint8[] memory cells) internal pure returns (uint256 b) {
        for (uint256 i; i < cells.length; ++i) b |= 1 << cells[i];
    }

    function _board(uint8[] memory ai, uint8[] memory hu) internal view returns (bytes memory) {
        return game.encodeX(_bits(ai), _bits(hu));
    }

    function _arr(uint8 a, uint8 b, uint8 c, uint8 d) internal pure returns (uint8[] memory r) {
        r = new uint8[](4);
        (r[0], r[1], r[2], r[3]) = (a, b, c, d);
    }

    // ------------------------------------------------------------------ G1: human wins
    function test_G1_humanWinEmitsAndAwardsBadge() public {
        AlephGomoku.AiPly[] memory plies = _plies(SHORT);
        vm.expectEmit(true, true, false, true, address(game));
        emit AlephGomoku.GameSettled(address(this), keccak256(SHORT), 1, 13);
        assertEq(game.settle(SHORT, plies), 1);
        assertEq(game.badges(address(this)), 1);
        assertTrue(game.settled(keccak256(SHORT)));
        assertEq(mock.verifyCalls(), 4); // AI plies 9 and 11 are rule plies (block open three, block five)
        assertEq(mock.lastKey(), KEY);
        assertEq(game.registry(), address(mock));
        assertEq(game.circuitKey(), KEY);
    }

    function test_G1b_aiWinNoBadge() public {
        AlephGomoku.AiPly[] memory plies = _plies(AIWIN);
        vm.expectEmit(true, true, false, true, address(game));
        emit AlephGomoku.GameSettled(address(this), keccak256(AIWIN), 2, 10);
        assertEq(game.settle(AIWIN, plies), 2);
        assertEq(game.badges(address(this)), 0);
    }

    function test_G1c_winsOnBothDiagonalsAndColumn() public {
        assertEq(game.settle(DIAG, _plies(DIAG)), 1);
        assertEq(game.settle(ANTI, _plies(ANTI)), 1);
        assertEq(game.settle(VERT, _plies(VERT)), 1);
        assertEq(game.badges(address(this)), 3);
    }

    function test_drawAt81() public {
        AlephGomoku.AiPly[] memory plies = _plies(DRAW);
        assertEq(plies.length, 40);
        vm.expectEmit(true, true, false, true, address(game));
        emit AlephGomoku.GameSettled(address(this), keccak256(DRAW), 3, 81);
        assertEq(game.settle(DRAW, plies), 3);
        assertEq(game.badges(address(this)), 0);
    }

    // edges: a run that wraps from col 8 to the next row's col 0 (→ or ↙) is not a five
    function test_edgeWrapIsNotFive() public {
        AlephGomoku.AiPly[] memory plies = _plies(WRAPH);
        vm.expectRevert(AlephGomoku.NotFinished.selector);
        game.settle(WRAPH, plies);
        plies = _plies(WRAPA);
        vm.expectRevert(AlephGomoku.NotFinished.selector);
        game.settle(WRAPA, plies);
    }

    // ------------------------------------------------------------------ G2: wrong AI move / bad proof
    function test_G2_wrongAiMoveReverts() public {
        // ply 1: y says 80 but the record says 79
        bytes memory moves = hex"014f";
        moves = bytes.concat(moves, hex"0250034e040005");
        AlephGomoku.AiPly[] memory plies = _plies(moves);
        plies[0].y = _y(80, 63);
        mock.setTruth(_x(moves, 1), plies[0].y);
        vm.expectRevert(abi.encodeWithSelector(AlephGomoku.WrongAiMove.selector, 1));
        game.settle(moves, plies);
    }

    function test_G2b_aiMustBlockEvenIfScoresSayOtherwise() public {
        // same as SHORT but the AI skips the forced open-three block at ply 9 (plays 76, which y favours)
        bytes memory moves = hex"2750284817082000294c26252a";
        AlephGomoku.AiPly[] memory plies = _plies(moves);
        vm.expectRevert(abi.encodeWithSelector(AlephGomoku.WrongAiMove.selector, 9));
        game.settle(moves, plies);
    }

    function test_G2c_badProofReverts() public {
        AlephGomoku.AiPly[] memory plies = _plies(SHORT);
        // tampered y (not the circuit's output) -> registry rejects
        plies[1].y = _y(79, 62);
        vm.expectRevert(MockAlephEval.InvalidProof.selector);
        game.settle(SHORT, plies);
        // every proof rejected
        plies = _plies(SHORT);
        mock.setFailVerify(true);
        vm.expectRevert(MockAlephEval.InvalidProof.selector);
        game.settle(SHORT, plies);
        // registry answering false instead of reverting
        mock.setFailVerify(false);
        mock.setReturnFalse(true);
        vm.expectRevert(abi.encodeWithSelector(AlephGomoku.ProofRejected.selector, 1));
        game.settle(SHORT, plies);
        assertFalse(game.settled(keccak256(SHORT)));
    }

    // ------------------------------------------------------------------ G3: occupied / out of range
    function test_G3_illegalMoves() public {
        bytes memory occ = hex"0150024f50"; // human plays on the AI's 80 at ply 4
        AlephGomoku.AiPly[] memory plies = _plies(occ);
        vm.expectRevert(abi.encodeWithSelector(AlephGomoku.IllegalMove.selector, 4));
        game.settle(occ, plies);

        bytes memory aiOcc = hex"0150020203"; // AI "plays" on human's 2 at ply 3
        plies = new AlephGomoku.AiPly[](2);
        plies[0].y = _y(80, 63);
        mock.setTruth(_x(aiOcc, 1), plies[0].y);
        vm.expectRevert(abi.encodeWithSelector(AlephGomoku.IllegalMove.selector, 3));
        game.settle(aiOcc, plies);

        vm.expectRevert(abi.encodeWithSelector(AlephGomoku.IllegalMove.selector, 0));
        game.settle(hex"51", new AlephGomoku.AiPly[](0)); // 81
        plies = _plies(hex"0150");
        vm.expectRevert(abi.encodeWithSelector(AlephGomoku.IllegalMove.selector, 2));
        game.settle(hex"0150ff", plies); // 255
    }

    // ------------------------------------------------------------------ G4: cached positions skip verify
    function test_G4_cachedSkipsVerify() public {
        AlephGomoku.AiPly[] memory plies = _plies(SHORT);
        mock.setCached(_x(SHORT, 1), plies[0].y);
        mock.setCached(_x(SHORT, 3), plies[1].y);
        plies[0].y = "";
        plies[1].y = ""; // proofs stay zero too
        assertEq(game.settle(SHORT, plies), 1);
        assertEq(mock.verifyCalls(), 2); // 4 proof plies, 2 of them cached
    }

    function test_G4b_missingProofReverts() public {
        AlephGomoku.AiPly[] memory plies = _plies(SHORT);
        plies[2].y = "";
        vm.expectRevert(abi.encodeWithSelector(AlephGomoku.MissingProof.selector, 5));
        game.settle(SHORT, plies);
    }

    // ------------------------------------------------------------------ G5: duplicate record
    function test_G5_alreadySettled() public {
        AlephGomoku.AiPly[] memory plies = _plies(SHORT);
        game.settle(SHORT, plies);
        vm.prank(address(0xB0B));
        vm.expectRevert(AlephGomoku.AlreadySettled.selector);
        game.settle(SHORT, plies);
        assertEq(game.badges(address(this)), 1);
        assertEq(game.badges(address(0xB0B)), 0);
    }

    // ------------------------------------------------------------------ G6: unfinished / moves after the end / ply count
    function test_G6_notFinished() public {
        bytes memory part = hex"2750284817082000290e2625"; // SHORT minus the winning move: 12 plies, no five
        AlephGomoku.AiPly[] memory plies = _plies(part);
        vm.expectRevert(AlephGomoku.NotFinished.selector);
        game.settle(part, plies);
        vm.expectRevert(AlephGomoku.NotFinished.selector);
        game.settle("", new AlephGomoku.AiPly[](0));
    }

    function test_G6b_movesAfterEnd() public {
        bytes memory more = bytes.concat(SHORT, hex"06"); // AI ply 13 after the human five
        AlephGomoku.AiPly[] memory plies = _plies(more);
        vm.expectRevert(abi.encodeWithSelector(AlephGomoku.MovesAfterEnd.selector, 13));
        game.settle(more, plies);
        more = bytes.concat(DRAW, hex"00"); // ply 81 after a full board (draw)
        plies = _plies(more);
        vm.expectRevert(abi.encodeWithSelector(AlephGomoku.MovesAfterEnd.selector, 81));
        game.settle(more, plies);
    }

    function test_G6c_plyCount() public {
        AlephGomoku.AiPly[] memory plies = new AlephGomoku.AiPly[](5);
        vm.expectRevert(AlephGomoku.PlyCount.selector);
        game.settle(SHORT, plies);
    }

    // ------------------------------------------------------------------ G7: full game, real registry, ~210k verifier
    /// Gas a GasBurnVerifier burns per call: GomokuGroth16Verifier.verifyProof measured ~210k (test_realProofGame logs it).
    uint256 constant VERIFIER_BURN = 210_000;

    function _realRegistry(address verifier) internal returns (AlephRegistry reg, bytes32 key) {
        MockFactory factory = new MockFactory();
        MockProcessor proc = new MockProcessor(address(factory));
        factory.setCPU(address(proc), true);
        proc.put(15, hex"02abababababababababababababababababababababab", 162, 486);
        reg = new AlephRegistry(address(factory));
        reg.allowProcessor(address(proc));
        key = reg.register(address(proc), 15, new AlephRegistry.CircuitRef[](0), verifier);
    }

    function _realPlies(bytes memory moves) internal pure returns (AlephGomoku.AiPly[] memory plies) {
        plies = new AlephGomoku.AiPly[](moves.length / 2);
        for (uint256 j; j < plies.length; ++j) plies[j].y = _y(uint8(moves[2 * j + 1]), 63);
    }

    function test_G7_longGameGas() public {
        (AlephRegistry reg, bytes32 key) = _realRegistry(address(new GasBurnVerifier(VERIFIER_BURN)));
        assertEq(reg.circuit(key).nPub, 3);
        AlephGomoku g = new AlephGomoku(address(reg), key);
        AlephGomoku.AiPly[] memory plies = _realPlies(LONG);
        assertEq(plies.length, 12);
        uint256 gasLimit = 600_000 * 10 + 400_000; // documented formula: 10 proof plies, 2 rule plies
        uint256 before = gasleft();
        uint8 r = g.settle{gas: gasLimit}(LONG, plies);
        uint256 used = before - gasleft();
        assertEq(r, 1);
        emit log_named_uint("settle gas, 10 AI plies verified + 2 rule plies (verifier burns 210k each)", used);
        emit log_named_uint("per verified AI ply (avg)", used / 10);
        assertLt(used, gasLimit);
        // replaying the same positions in another record now needs no proofs at all
        (bool proven,) = reg.getResult(key, _x(LONG, 1));
        assertTrue(proven);
    }

    function test_G7b_cachedLongGameGas() public {
        (AlephRegistry reg, bytes32 key) = _realRegistry(address(new GasBurnVerifier(VERIFIER_BURN)));
        AlephGomoku g = new AlephGomoku(address(reg), key);
        AlephGomoku.AiPly[] memory plies = _realPlies(LONG);
        for (uint256 j; j < plies.length; ++j) {
            bytes memory x = _x(LONG, 2 * j + 1);
            if (g.needsProof(x)) reg.verifyEval(key, x, plies[j].y, plies[j].proof);
        }
        AlephGomoku.AiPly[] memory empty = new AlephGomoku.AiPly[](12);
        uint256 before = gasleft();
        g.settle{gas: 400_000}(LONG, empty); // documented formula with 0 plies to verify
        emit log_named_uint("settle gas, 10 proof plies cached + 2 rule plies", before - gasleft());
    }

    function test_G7c_tooLittleGasReverts() public {
        (AlephRegistry reg, bytes32 key) = _realRegistry(address(new GasBurnVerifier(VERIFIER_BURN)));
        AlephGomoku g = new AlephGomoku(address(reg), key);
        AlephGomoku.AiPly[] memory plies = _realPlies(SHORT);
        vm.expectRevert(AlephRegistry.InsufficientGas.selector);
        g.settle{gas: 1_000_000}(SHORT, plies); // 4 verifies (+2 rule plies) need 600k*4 + 400k
        assertEq(g.settle{gas: 600_000 * 4 + 400_000}(SHORT, plies), 1);
    }

    // ------------------------------------------------------------------ G8: rule plies need no proof
    /// Any registry read for one of these positions reverts the whole settle.
    function _forbidRegistryReads(bytes memory moves, uint256[2] memory rulePlies) internal {
        for (uint256 i; i < 2; ++i) {
            vm.mockCallRevert(
                address(mock),
                abi.encodeWithSelector(MockAlephEval.getResult.selector, KEY, _x(moves, rulePlies[i])),
                "rule ply read the registry"
            );
            vm.expectRevert(bytes("rule ply read the registry")); // the mock really bites
            mock.getResult(KEY, _x(moves, rulePlies[i]));
        }
    }

    /// SHORT's AI plies 9 (block the open three) and 11 (block five) are decided by rules 1–4.
    function test_G8_rulePlyWithEmptyProofSettles() public {
        AlephGomoku.AiPly[] memory plies = _plies(SHORT);
        plies[4].y = "";
        plies[5].y = ""; // proofs stay zero, positions not cached
        _forbidRegistryReads(SHORT, [uint256(9), 11]);
        assertEq(game.settle(SHORT, plies), 1);
        assertEq(mock.verifyCalls(), 4);
    }

    function test_G8b_rulePlyGarbageIsIgnored() public {
        AlephGomoku.AiPly[] memory plies = _plies(SHORT);
        plies[4].y = hex"deadbeef"; // wrong length
        plies[5].y = _y(70, 63); // well-formed, argmax would pick 70 instead of the forced 37; never verified
        plies[5].proof[0] = 0xbad;
        _forbidRegistryReads(SHORT, [uint256(9), 11]);
        assertEq(game.settle(SHORT, plies), 1);
        assertEq(mock.verifyCalls(), 4);
    }

    function test_G8c_needsProof() public view {
        bool[6] memory want = [true, true, true, true, false, false];
        for (uint256 j; j < 6; ++j) assertEq(game.needsProof(_x(SHORT, 2 * j + 1)), want[j]);
        assertFalse(game.needsProof(_board(_arr(73, 74, 75, 76), _arr(1, 2, 3, 4)))); // AI five
        assertFalse(game.needsProof(_board(_arr(80, 79, 0, 8), _arr(39, 40, 41, 72)))); // human open three
        assertTrue(game.needsProof(_board(_arr(80, 79, 78, 60), _arr(0, 1, 2, 44)))); // edge three is not open
        assertTrue(game.needsProof(new bytes(21))); // empty board
    }

    function test_G8d_needsProofRejectsBadInput() public {
        vm.expectRevert(AlephGomoku.BadInput.selector);
        game.needsProof(new bytes(20));
        bytes memory x = new bytes(21);
        x[20] = 0x04; // bit 162: non-canonical padding
        vm.expectRevert(AlephGomoku.BadInput.selector);
        game.needsProof(x);
    }

    // ------------------------------------------------------------------ selection rule
    function test_select_winTakesPriorityOverBlock() public view {
        // AI 73..76 (win cells 72, 77), human 1..4 (win cells 0, 5); y favours 40
        bytes memory x = _board(_arr(73, 74, 75, 76), _arr(1, 2, 3, 4));
        assertEq(game.select(x, _y(40, 63)), 72);
    }

    function test_select_blockBeatsArgmax() public view {
        // human 1..4 -> must block the lowest of {0, 5}
        bytes memory x = _board(_arr(80, 79, 78, 60), _arr(1, 2, 3, 4));
        assertEq(game.select(x, _y(40, 63)), 0);
        // human 0..3 -> only 4 (no cell left of col 0)
        x = _board(_arr(80, 79, 78, 60), _arr(0, 1, 2, 3));
        assertEq(game.select(x, _y(40, 63)), 4);
        // broken four 10,11,_,13,14 -> fill 12
        x = _board(_arr(80, 79, 78, 60), _arr(10, 11, 13, 14));
        assertEq(game.select(x, _y(40, 63)), 12);
    }

    function test_select_openFourRules() public view {
        // human open three 39,40,41 (row 4): open-four cells 38 and 42 -> AI blocks 38 (lowest), not y's 70
        assertEq(game.select(_board(_arr(80, 79, 0, 8), _arr(39, 40, 41, 72)), _y(70, 63)), 38);
        // AI's own open three beats blocking: AI 21,22,23 -> AI makes an open four at 20 (lowest)
        assertEq(game.select(_board(_arr(21, 22, 23, 80), _arr(39, 40, 41, 72)), _y(70, 63)), 20);
        // human three at the left edge 0,1,2: placing 3 gives 0..3 with no cell left of 0 -> not open; y wins
        assertEq(game.select(_board(_arr(80, 79, 78, 60), _arr(0, 1, 2, 44)), _y(70, 63)), 70);
        // broken three 39,_,41,42: filling 40 makes an open four (38 and 43 empty)
        assertEq(game.select(_board(_arr(80, 79, 0, 8), _arr(39, 41, 42, 72)), _y(70, 63)), 40);
    }

    function test_select_diagonalWinCells() public view {
        // AI on ↘ 20,30,40,50 -> win cells 10, 60
        assertEq(game.select(_board(_arr(20, 30, 40, 50), _arr(0, 1, 2, 3)), _y(70, 63)), 10);
        // AI on ↙ 16,24,32,40 -> win cells 8, 48 (beats human's block at 4)
        assertEq(game.select(_board(_arr(16, 24, 32, 40), _arr(0, 1, 2, 3)), _y(70, 63)), 8);
        // human on ↙ 12,20,28,36 -> block 4 ((5,-1) is off the board)
        assertEq(game.select(_board(_arr(80, 79, 78, 60), _arr(12, 20, 28, 36)), _y(70, 63)), 4);
    }

    function test_select_edgeWrapIsNotAThreat() public view {
        // human 6,7,8 | 9 (row wrap) and 20,28,36 | 44 (↙ wrap): no real win cell, so argmax (50) wins
        assertEq(game.select(_board(_arr(80, 79, 78, 60), _arr(6, 7, 8, 9)), _y(50, 63)), 50);
        assertEq(game.select(_board(_arr(80, 79, 78, 60), _arr(20, 28, 36, 44)), _y(50, 63)), 50);
        // AI 72..75 on the bottom row (no wrap to row 9): only 76 wins
        assertEq(game.select(_board(_arr(72, 73, 74, 75), _arr(0, 2, 4, 6)), _y(50, 63)), 76);
    }

    function test_select_argmaxTieBreakAndOccupied() public view {
        bytes memory y = _y(30, 50);
        _setScore(y, 60, 50);
        _setScore(y, 10, 49);
        _setScore(y, 5, 63); // occupied below
        uint8[] memory hu = new uint8[](1);
        hu[0] = 5;
        assertEq(game.select(_board(new uint8[](0), hu), y), 30);
        // all zero -> lowest empty cell
        assertEq(game.select(_board(new uint8[](0), hu), new bytes(61)), 0);
        hu[0] = 0;
        assertEq(game.select(_board(new uint8[](0), hu), new bytes(61)), 1);
    }

    function test_select_scoreDecodeBoundaries() public view {
        bytes memory empty = new bytes(21);
        uint256[3] memory cells = [uint256(0), 42, 80]; // 42 straddles the 256-bit word boundary
        uint256[3] memory scores = [uint256(1), 32, 33];
        for (uint256 i; i < 3; ++i) {
            for (uint256 s; s < 3; ++s) {
                assertEq(game.select(empty, _y(cells[i], scores[s])), cells[i]);
            }
        }
        bytes memory y = _y(42, 33);
        _setScore(y, 43, 32);
        _setScore(y, 41, 32);
        assertEq(game.select(empty, y), 42);
    }

    function test_select_rejectsBadInput() public {
        vm.expectRevert(AlephGomoku.BadInput.selector);
        game.select(new bytes(20), new bytes(61));
        vm.expectRevert(AlephGomoku.BadInput.selector);
        game.select(new bytes(21), new bytes(60));
        bytes memory x = new bytes(21);
        x[0] = 0x01; // AI stone at 0
        x[10] = 0x02; // bit 81 = human stone at 0 too
        vm.expectRevert(AlephGomoku.BadInput.selector);
        game.select(x, new bytes(61));
    }

    function test_encodeXMatchesSpec() public view {
        assertEq(game.encodeX(_bits(_arr(0, 80, 9, 40)), _bits(_arr(1, 2, 10, 79))), _x(hex"010002500a094f28", 8));
        // human at 80 is bit 161 -> byte 20, bit 1
        uint8[] memory hu = new uint8[](1);
        hu[0] = 80;
        bytes memory x = _board(new uint8[](0), hu);
        assertEq(uint8(x[20]), 2);
    }

    // ------------------------------------------------------------------ reference vectors (circuit agent)
    struct Vec {
        uint256 move;
        bytes x;
        bytes y;
    }

    /// circuits/gomoku/vectors.json: [{x: "0x..21B", y: "0x..61B", move: <number or "0x..">}]; skipped if absent.
    function test_referenceVectors() public {
        string memory path = string.concat(vm.projectRoot(), "/../circuits/gomoku/vectors.json");
        if (!vm.exists(path)) {
            vm.skip(true, "circuits/gomoku/vectors.json not present yet");
            return;
        }
        string memory j = vm.readFile(path);
        Vec[] memory v = abi.decode(vm.parseJsonTypeArray(j, "$", "Vec(uint256 move,bytes x,bytes y)"), (Vec[]));
        assertGt(v.length, 0);
        uint256 proofPlies;
        for (uint256 i; i < v.length; ++i) {
            assertEq(game.select(v[i].x, v[i].y), v[i].move, string.concat("vector ", vm.toString(i)));
            if (game.needsProof(v[i].x)) ++proofPlies;
        }
        // vector mix: 600 vectors decided by rule 5, 100 by each of rules 1–4
        if (v.length == 1000) assertEq(proofPlies, 600);
        emit log_named_uint("reference vectors matched", v.length);
        emit log_named_uint("reference vectors needing a proof (rule 5)", proofPlies);
    }

    // ------------------------------------------------------------------ real proofs (circuit agent)
    /// test/fixtures/gomoku_proofs.json: {moves: "0x..", cases: [{xHex, yHex, pub, proof[24]}]}, cases 1:1 with
    /// AI plies; verified by the real GomokuGroth16Verifier behind the real AlephRegistry. Skipped if absent.
    function test_realProofGame() public {
        string memory path = string.concat(vm.projectRoot(), "/test/fixtures/gomoku_proofs.json");
        if (!vm.exists(path)) {
            vm.skip(true, "test/fixtures/gomoku_proofs.json not present yet");
            return;
        }
        string memory fx = vm.readFile(path);
        address verifier = vm.deployCode("GomokuGroth16Verifier.sol:GomokuGroth16Verifier");
        (AlephRegistry reg, bytes32 key) = _realRegistry(verifier);
        AlephGomoku g = new AlephGomoku(address(reg), key);
        bytes memory moves = fx.readBytes(".moves");
        AlephGomoku.AiPly[] memory plies = new AlephGomoku.AiPly[](moves.length / 2);
        for (uint256 i; i < plies.length; ++i) {
            string memory p = string.concat(".cases[", vm.toString(i), "]");
            assertEq(fx.readBytes(string.concat(p, ".xHex")), _x(moves, 2 * i + 1), "fixture x != board");
            plies[i].y = fx.readBytes(string.concat(p, ".yHex"));
            bytes32[] memory w = fx.readBytes32Array(string.concat(p, ".proof"));
            for (uint256 k; k < 24; ++k) plies[i].proof[k] = uint256(w[k]);
        }
        uint256 toVerify; // every ply carries a proof; rule plies (rules 1–4) just ignore theirs
        uint256 first = type(uint256).max;
        for (uint256 i; i < plies.length; ++i) {
            if (!g.needsProof(_x(moves, 2 * i + 1))) continue;
            if (toVerify++ == 0) first = i;
        }
        uint256 before = gasleft();
        uint8 r = g.settle{gas: 600_000 * toVerify + 400_000}(moves, plies); // documented formula
        uint256 used = before - gasleft();
        assertGt(r, 0);
        emit log_named_uint("real-proof settle result", r);
        emit log_named_uint("real-proof AI plies", plies.length);
        emit log_named_uint("real-proof AI plies verified (rule 5)", toVerify);
        emit log_named_uint("real-proof settle gas", used);
        _logVerifierGas(verifier, fx, first, plies[first].proof);
    }

    /// GomokuGroth16Verifier.verifyProof alone (24-word wrapper + self-call into the snarkjs verifier, 3 public inputs).
    function _logVerifierGas(address verifier, string memory fx, uint256 i, uint256[24] memory proof) internal {
        uint256[] memory pv = fx.readUintArray(string.concat(".cases[", vm.toString(i), "].pub"));
        uint256[3] memory pub = [pv[0], pv[1], pv[2]];
        uint256 g0 = gasleft();
        (bool ok, bytes memory ret) =
            verifier.staticcall(abi.encodeWithSignature("verifyProof(uint256[24],uint256[3])", proof, pub));
        uint256 used = g0 - gasleft();
        assertTrue(ok && abi.decode(ret, (bool)), "real proof must verify");
        emit log_named_uint("GomokuGroth16Verifier.verifyProof gas (warm address)", used);
        assertLt(used, VERIFIER_BURN + 10_000);
    }
}
