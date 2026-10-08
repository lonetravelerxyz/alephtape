// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {AlephGomokuArena} from "../src/AlephGomokuArena.sol";
import {AlephRegistry} from "../src/AlephRegistry.sol";
import {AlephSnake} from "../src/AlephSnake.sol";
import {AlephGame2048} from "../src/AlephGame2048.sol";
import {AlephFlappy} from "../src/AlephFlappy.sol";
import {MockFactory, MockProcessor} from "./mocks/MockTapeOut.sol";
import {TruthVerifier} from "./mocks/TruthVerifier.sol";

/// Spec A1–A10. Real AlephRegistry; each AI circuit's verifier is a TruthVerifier
/// (accepts p[0] == keccak(public words), so a proof binds one (x, y)). Games come from the Python arena reference
/// (contracts/test/fixtures/arena_games.json): real house-model matches with the circuit's real scores
/// per network ply. Keys here differ from the fixture's, so each game is replayed under a nonce whose seed yields
/// the fixture's opening (the seed/opening derivation itself is checked against Python with the fixture keys).
/// Seeds are bound to no address: SENDER stands for whoever settles, and A7b settles from a stranger.
contract AlephGomokuArenaTest is Test {
    using stdJson for string;

    AlephRegistry reg;
    AlephGomokuArena arena;
    MockProcessor proc;
    bytes32 keyA; // fixture "black of even nonces"
    bytes32 keyB;
    address constant SENDER = address(0xA11E);
    address constant OWNER = address(0xB0B);
    string fx;

    function setUp() public {
        MockFactory factory = new MockFactory();
        proc = new MockProcessor(address(factory));
        factory.setCPU(address(proc), true);
        proc.put(15, hex"02abababab", 162, 486);
        proc.put(16, hex"02cdcdcdcd", 64, 1);
        reg = new AlephRegistry(address(factory));
        reg.allowProcessor(address(proc));
        keyA = reg.register(address(proc), 15, new AlephRegistry.CircuitRef[](0), address(new TruthVerifier(0)));
        keyB = reg.register(address(proc), 15, new AlephRegistry.CircuitRef[](0), address(new TruthVerifier(0)));
        arena = new AlephGomokuArena(address(reg));
        fx = vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/arena_games.json"));
        _loadPlies();
    }

    // ------------------------------------------------------------------ helpers
    function _enterBoth() internal {
        vm.prank(OWNER);
        arena.enter(keyA, unicode"ℵ-A");
        vm.prank(OWNER);
        arena.enter(keyB, unicode"ℵ-B");
    }

    /// little-endian 31-byte chunks -> field elements (AlephRegistry._words)
    function _words(bytes memory b) internal pure returns (uint256[] memory w) {
        uint256 n = (b.length + 30) / 31;
        w = new uint256[](n);
        for (uint256 c; c < n; ++c) {
            uint256 v;
            uint256 end = (c + 1) * 31;
            if (end > b.length) end = b.length;
            for (uint256 j = end; j > c * 31; --j) {
                v = (v << 8) | uint8(b[j - 1]);
            }
            w[c] = v;
        }
    }

    function _proof(bytes memory x, bytes memory y) internal pure returns (uint256[24] memory p) {
        uint256[] memory xw = _words(x);
        uint256[] memory yw = _words(y);
        p[0] = uint256(keccak256(abi.encode(xw[0], yw[0], yw[1])));
    }

    struct ArenaGame {
        bytes moves;
        uint8 result;
        uint8 o0;
        uint8 o1;
        bool aBlack; // fixture black = keyA
        uint256 n;
    }

    function _game(uint256 g) internal view returns (ArenaGame memory G) {
        string memory p = string.concat(".games[", vm.toString(g), "]");
        G.moves = fx.readBytes(string.concat(p, ".moves"));
        G.result = uint8(fx.readUint(string.concat(p, ".result")));
        G.o0 = uint8(G.moves[0]);
        G.o1 = uint8(G.moves[1]);
        G.aBlack = fx.readUint(string.concat(p, ".nonce")) % 2 == 0;
        G.n = G.moves.length;
    }

    // Per-ply data of every fixture game, read once in setUp (re-parsing the JSON per ply runs out of memory
    // on 81-ply games).
    bytes[][] internal gx;
    bytes[][] internal gy;
    uint256[][] internal gr;

    function _loadPlies() internal {
        for (uint256 g; g < 6; ++g) {
            string memory p = string.concat(".games[", vm.toString(g), "]");
            gx.push(fx.readBytesArray(string.concat(p, ".xs")));
            gy.push(fx.readBytesArray(string.concat(p, ".ys")));
            gr.push(fx.readUintArray(string.concat(p, ".rules")));
        }
    }

    function _plyX(uint256 g, uint256 j) internal view returns (bytes memory) {
        return gx[g][j];
    }

    function _plyY(uint256 g, uint256 j) internal view returns (bytes memory) {
        return gy[g][j];
    }

    function _plyRule(uint256 g, uint256 j) internal view returns (uint256) {
        return gr[g][j];
    }

    /// Plies with y + a valid proof on network plies, empty on rule plies.
    function _plies(uint256 g, ArenaGame memory G) internal view returns (AlephGomokuArena.AiPly[] memory plies) {
        plies = new AlephGomokuArena.AiPly[](G.n - 2);
        for (uint256 j; j < plies.length; ++j) {
            if (_plyRule(g, j) != 5) continue;
            bytes memory y = _plyY(g, j);
            plies[j].y = y;
            plies[j].proof = _proof(_plyX(g, j), y);
        }
    }

    function _sides(ArenaGame memory G) internal view returns (bytes32 black, bytes32 white) {
        (black, white) = G.aBlack ? (keyA, keyB) : (keyB, keyA);
    }

    /// A nonce whose seed (for these keys) opens with the fixture game's two cells.
    function _nonceFor(ArenaGame memory G) internal view returns (uint256) {
        (bytes32 black, bytes32 white) = _sides(G);
        for (uint256 nonce; nonce < 50_000; ++nonce) {
            (uint8 a, uint8 b) = arena.opening(arena.matchSeed(black, white, nonce));
            if (a == G.o0 && b == G.o1) return nonce;
        }
        revert("no nonce");
    }

    /// settleMatch as SENDER with an explicit gas limit; gas measured around the call only (calldata pre-encoded,
    /// so the test contract's own memory expansion is not counted; excludes the tx base cost and calldata gas).
    function _measuredSettle(
        uint256 limit,
        bytes32 black,
        bytes32 white,
        uint256 nonce,
        bytes memory moves,
        AlephGomokuArena.AiPly[] memory plies
    ) internal returns (uint8 r, uint256 used) {
        bytes memory data = abi.encodeCall(AlephGomokuArena.settleMatch, (black, white, nonce, moves, plies));
        vm.prank(SENDER);
        (bool ok, bytes memory ret) = address(arena).call{gas: limit}(data);
        assertTrue(ok, "settleMatch reverted");
        r = abi.decode(ret, (uint8));
        // vm.lastCallGas(): read the first two words (gasLimit, gasTotalUsed) by hand — this forge build returns a
        // shorter Gas struct than the vendored forge-std declares
        (, bytes memory g) = address(vm).staticcall(abi.encodeWithSignature("lastCallGas()"));
        (, uint64 total) = abi.decode(g, (uint64, uint64));
        used = total;
    }

    function _settle(uint256 g) internal returns (uint8) {
        ArenaGame memory G = _game(g);
        (bytes32 black, bytes32 white) = _sides(G);
        uint256 nonce = _nonceFor(G);
        AlephGomokuArena.AiPly[] memory plies = _plies(g, G);
        vm.prank(SENDER);
        return arena.settleMatch(black, white, nonce, G.moves, plies);
    }

    // ------------------------------------------------------------------ A1: entry
    function test_A1_enter() public {
        vm.expectEmit(true, true, false, true);
        emit AlephGomokuArena.Entered(keyA, OWNER, unicode"ℵ-A");
        vm.prank(OWNER);
        arena.enter(keyA, unicode"ℵ-A");
        AlephGomokuArena.Entrant memory e = arena.entrant(keyA);
        assertEq(e.owner, OWNER);
        assertEq(e.elo, 1200);
        assertEq(e.name, unicode"ℵ-A");
        assertEq(arena.entrantCount(), 1);
        assertEq(arena.keys(0), keyA);
        vm.expectRevert(AlephGomokuArena.AlreadyEntered.selector);
        arena.enter(keyA, "again"); // anyone, but only once per circuit
    }

    function test_A1b_enterRejectsWrongInterfaceAndUnknownKey() public {
        bytes32 bnnLike = reg.register(address(proc), 16, new AlephRegistry.CircuitRef[](0), address(new TruthVerifier(0)));
        vm.expectRevert(abi.encodeWithSelector(AlephGomokuArena.WrongInterface.selector, uint32(64), uint32(1)));
        arena.enter(bnnLike, "bnn");
        vm.expectRevert(AlephGomokuArena.UnknownCircuit.selector);
        arena.enter(keccak256("not registered"), "ghost");
        vm.expectRevert(AlephGomokuArena.BadName.selector);
        arena.enter(keyA, "");
        vm.expectRevert(AlephGomokuArena.BadName.selector);
        arena.enter(keyA, "0123456789abcdef0123456789abcdef!"); // 33 bytes
        assertEq(arena.entrantCount(), 0);
    }

    function test_A1c_entrantsPage() public {
        _enterBoth();
        (bytes32[] memory ks, AlephGomokuArena.Entrant[] memory es) = arena.entrantsPage(0, 10);
        assertEq(ks.length, 2);
        assertEq(ks[1], keyB);
        assertEq(es[1].name, unicode"ℵ-B");
        (ks,) = arena.entrantsPage(5, 10);
        assertEq(ks.length, 0);
    }

    // ------------------------------------------------------------------ A2: seed and opening = Python
    function test_A2_seedAndOpeningMatchPython() public view {
        for (uint256 g; g < 6; ++g) {
            string memory p = string.concat(".games[", vm.toString(g), "]");
            bytes32 seed = arena.matchSeed(
                fx.readBytes32(string.concat(p, ".black")),
                fx.readBytes32(string.concat(p, ".white")),
                fx.readUint(string.concat(p, ".nonce"))
            );
            assertEq(seed, fx.readBytes32(string.concat(p, ".seed")));
            (uint8 a, uint8 b) = arena.opening(seed);
            uint256[] memory o = fx.readUintArray(string.concat(p, ".opening"));
            assertEq(a, o[0]);
            assertEq(b, o[1]);
        }
    }

    function test_A2b_openingIsCentralAndDistinct() public view {
        for (uint256 i; i < 300; ++i) {
            (uint8 a, uint8 b) = arena.opening(keccak256(abi.encode(i)));
            assertTrue(a != b);
            for (uint256 k; k < 2; ++k) {
                uint256 c = k == 0 ? a : b;
                assertTrue(c / 9 >= 2 && c / 9 <= 6 && c % 9 >= 2 && c % 9 <= 6);
            }
        }
    }

    // ------------------------------------------------------------------ A3: correct matches
    /// One game per external call: fresh memory (the JSON reads are memory-hungry).
    function settleFixtureGame(uint256 g) external returns (uint8) {
        return _settle(g);
    }

    function test_A3_fixtureMatchesSettle() public {
        _enterBoth();
        uint32[3] memory a; // A wins, draws, losses
        for (uint256 g; g < 6; ++g) {
            ArenaGame memory G = _game(g);
            uint8 r = this.settleFixtureGame(g);
            assertEq(r, G.result, "result = Python");
            if (r == 3) a[1]++;
            else if ((r == 1) == G.aBlack) a[0]++;
            else a[2]++;
        }
        AlephGomokuArena.Entrant memory A = arena.entrant(keyA);
        AlephGomokuArena.Entrant memory B = arena.entrant(keyB);
        assertEq(A.wins, a[0]);
        assertEq(A.draws, a[1]);
        assertEq(A.losses, a[2]);
        assertEq(B.wins, a[2]);
        assertEq(B.losses, a[0]);
        assertEq(int256(A.elo) + int256(B.elo), 2400, "Elo is zero-sum");
    }

    function test_A3b_emitsMatchSettled() public {
        _enterBoth();
        ArenaGame memory G = _game(0);
        (bytes32 black, bytes32 white) = _sides(G);
        uint256 nonce = _nonceFor(G);
        bytes32 seed = arena.matchSeed(black, white, nonce);
        AlephGomokuArena.AiPly[] memory plies = _plies(0, G);
        vm.expectEmit(true, true, true, true);
        emit AlephGomokuArena.MatchSettled(black, white, SENDER, seed, G.result, uint16(G.n));
        vm.prank(SENDER);
        arena.settleMatch(black, white, nonce, G.moves, plies);
        assertTrue(arena.settled(seed));
    }

    // ------------------------------------------------------------------ A4: wrong moves / opening
    function test_A4_wrongMoveReverts() public {
        _enterBoth();
        ArenaGame memory G = _game(0);
        (bytes32 black, bytes32 white) = _sides(G);
        uint256 nonce = _nonceFor(G);
        AlephGomokuArena.AiPly[] memory plies = _plies(0, G);
        // first network ply: point it at another empty cell
        uint256 j;
        while (_plyRule(0, j) != 5) ++j;
        bytes memory bad = bytes(G.moves);
        uint8 alt = uint8(bad[j + 2]);
        for (uint8 c; c < 81; ++c) {
            bool used;
            for (uint256 k; k <= j + 2; ++k) if (uint8(bad[k]) == c) used = true;
            if (!used) {
                alt = c;
                break;
            }
        }
        bad[j + 2] = bytes1(alt);
        vm.prank(SENDER);
        vm.expectRevert(abi.encodeWithSelector(AlephGomokuArena.WrongMove.selector, j + 2));
        arena.settleMatch(black, white, nonce, bad, plies);
    }

    function test_A4b_badOpeningAndIllegalMove() public {
        _enterBoth();
        ArenaGame memory G = _game(1);
        (bytes32 black, bytes32 white) = _sides(G);
        uint256 nonce = _nonceFor(G);
        AlephGomokuArena.AiPly[] memory plies = _plies(1, G);
        bytes memory bad = bytes.concat(G.moves);
        bad[0] = bytes1(uint8(80)); // corner, never a central opening cell
        vm.startPrank(SENDER);
        vm.expectRevert(abi.encodeWithSelector(AlephGomokuArena.BadOpening.selector, 0));
        arena.settleMatch(black, white, nonce, bad, plies);
        bad = bytes.concat(G.moves);
        bad[2] = bad[0]; // occupied
        vm.expectRevert(abi.encodeWithSelector(AlephGomokuArena.IllegalMove.selector, 2));
        arena.settleMatch(black, white, nonce, bad, plies);
        bad[2] = bytes1(uint8(81));
        vm.expectRevert(abi.encodeWithSelector(AlephGomokuArena.IllegalMove.selector, 2));
        arena.settleMatch(black, white, nonce, bad, plies);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ A5: bad / missing proofs
    function test_A5_badProofReverts() public {
        _enterBoth();
        ArenaGame memory G = _game(0);
        (bytes32 black, bytes32 white) = _sides(G);
        uint256 nonce = _nonceFor(G);
        AlephGomokuArena.AiPly[] memory plies = _plies(0, G);
        uint256 j;
        while (_plyRule(0, j) != 5) ++j;
        plies[j].proof[0] ^= 1; // tampered proof
        vm.startPrank(SENDER);
        vm.expectRevert(AlephRegistry.InvalidProof.selector);
        arena.settleMatch(black, white, nonce, G.moves, plies);
        plies[j].proof = _proof(_plyX(0, j), _plyY(0, j));
        plies[j].y[0] ^= 0x01; // tampered y, proof for the real y
        vm.expectRevert(AlephRegistry.InvalidProof.selector);
        arena.settleMatch(black, white, nonce, G.moves, plies);
        plies[j].y = ""; // nothing at all
        vm.expectRevert(abi.encodeWithSelector(AlephGomokuArena.MissingProof.selector, j + 2));
        arena.settleMatch(black, white, nonce, G.moves, plies);
        vm.stopPrank();
    }

    function test_A5b_proofOfTheOtherCircuitIsRejected() public {
        // the proof binds (x, y) but the verifier belongs to one key: a ply proven under the opponent's key is no proof
        // of this side's circuit. Pre-cache every network position under the WRONG key: settle must still ask for proofs.
        _enterBoth();
        ArenaGame memory G = _game(0);
        (bytes32 black, bytes32 white) = _sides(G);
        uint256 nonce = _nonceFor(G);
        AlephGomokuArena.AiPly[] memory plies = _plies(0, G);
        uint256 j;
        while (_plyRule(0, j) != 5) ++j;
        bytes32 own = (j % 2 == 0) ? black : white; // ply j+2: even -> black
        bytes32 other = own == black ? white : black;
        reg.verifyEval(other, _plyX(0, j), plies[j].y, plies[j].proof);
        plies[j].y = "";
        vm.prank(SENDER);
        vm.expectRevert(abi.encodeWithSelector(AlephGomokuArena.MissingProof.selector, j + 2));
        arena.settleMatch(black, white, nonce, G.moves, plies);
    }

    // ------------------------------------------------------------------ A6: cached plies need nothing
    function test_A6_cachedPliesSkipVerify() public {
        _enterBoth();
        ArenaGame memory G = _game(2);
        (bytes32 black, bytes32 white) = _sides(G);
        uint256 nonce = _nonceFor(G);
        AlephGomokuArena.AiPly[] memory plies = _plies(2, G);
        uint256 net;
        for (uint256 j; j < plies.length; ++j) {
            if (plies[j].y.length == 0) continue;
            reg.verifyEval((j % 2 == 0) ? black : white, _plyX(2, j), plies[j].y, plies[j].proof);
            net++;
        }
        assertGt(net, 0);
        AlephGomokuArena.AiPly[] memory empty = new AlephGomokuArena.AiPly[](G.n - 2);
        (uint8 r, uint256 used) = _measuredSettle(400_000 + 25_000 * G.n, black, white, nonce, G.moves, empty);
        emit log_named_uint("plies", G.n);
        emit log_named_uint("network plies (all cached)", net);
        emit log_named_uint("all cached settle gas", used);
        assertEq(r, G.result);
        assertLt(used, 400_000 + 25_000 * G.n); // documented: 600k x (to verify) + 25k x plies + 400k
    }

    // ------------------------------------------------------------------ A7: one settle per seed
    function test_A7_duplicateSeed() public {
        _enterBoth();
        ArenaGame memory G = _game(3);
        (bytes32 black, bytes32 white) = _sides(G);
        uint256 nonce = _nonceFor(G);
        AlephGomokuArena.AiPly[] memory plies = _plies(3, G);
        vm.startPrank(SENDER);
        arena.settleMatch(black, white, nonce, G.moves, plies);
        vm.expectRevert(AlephGomokuArena.AlreadySettled.selector);
        arena.settleMatch(black, white, nonce, G.moves, plies);
        vm.stopPrank();
        // the seed binds no address: another sender has the same seed, already settled
        vm.prank(address(0xBEEF));
        vm.expectRevert(AlephGomokuArena.AlreadySettled.selector);
        arena.settleMatch(black, white, nonce, G.moves, plies);
    }

    struct Settle {
        bytes32 black;
        bytes32 white;
        uint256 nonce;
        bytes32 seed;
        bytes moves;
        uint8 result;
        AlephGomokuArena.AiPly[] plies;
    }

    function _settleArgs(uint256 g) internal view returns (Settle memory m) {
        ArenaGame memory G = _game(g);
        (m.black, m.white) = _sides(G);
        m.nonce = _nonceFor(G);
        m.seed = arena.matchSeed(m.black, m.white, m.nonce);
        m.moves = G.moves;
        m.result = G.result;
        m.plies = _plies(g, G);
    }

    function _settleAs(address who, Settle memory m) internal returns (uint8) {
        vm.prank(who);
        return arena.settleMatch(m.black, m.white, m.nonce, m.moves, m.plies);
    }

    /// A seed is global. A match "played" in the browser as the no-wallet simulation address settles from any
    /// other address, which MatchSettled names as the settler; Elo and W/D/L are applied once; after that nobody can
    /// settle the seed again, the simulation address and earlier settlers included.
    function test_A7b_anyAddressSettlesOnceGlobally() public {
        _enterBoth();
        Settle memory m = _settleArgs(3);
        address sim = address(0xa1e9A1E9); // the site's simulation sender
        address wallet = address(0xBEEF);
        // the dry run the page does without a wallet (an eth_call from the simulation address) passes ...
        uint256 snap = vm.snapshotState();
        assertEq(_settleAs(sim, m), m.result);
        vm.revertToState(snap);
        assertFalse(arena.settled(m.seed));
        // ... and the real settle comes from a wallet connected afterwards, named in the event
        vm.expectEmit(true, true, true, true, address(arena));
        emit AlephGomokuArena.MatchSettled(m.black, m.white, wallet, m.seed, m.result, uint16(m.moves.length));
        assertEq(_settleAs(wallet, m), m.result);
        int32 d = m.result == 1 ? int32(16) : (m.result == 2 ? int32(-16) : int32(0));
        AlephGomokuArena.Entrant memory b = arena.entrant(m.black);
        assertEq(b.elo, 1200 + d);
        assertEq(arena.entrant(m.white).elo, 1200 - d);
        assertEq(uint256(b.wins) + b.draws + b.losses, 1, "rated once");
        address[3] memory others = [sim, SENDER, wallet];
        for (uint256 i; i < 3; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(AlephGomokuArena.AlreadySettled.selector);
            arena.settleMatch(m.black, m.white, m.nonce, m.moves, m.plies);
        }
        assertEq(arena.entrant(m.black).elo, 1200 + d, "no second rating");
    }

    /// Seed = keccak256(abi.encode(keccak256("AlephTape.arena.v2"), black, white, nonce)); golden values shared
    /// with the Python and TypeScript references.
    function test_A7c_seedDomain() public view {
        bytes32 a = keccak256("gomoku_attack");
        bytes32 b = keccak256("gomoku_solid");
        assertEq(arena.SEED_DOMAIN(), 0xc81a453c467dd2e89ef68438fe53bac175fd118c8f690215ce4e31d69d9fb207);
        assertEq(arena.matchSeed(a, b, 7), 0x3744f9a6aebdc78917a41d1e7df47a7c606c55df6732cd6fe6d14e9e2d25cf67);
        assertEq(arena.matchSeed(a, b, 7), keccak256(abi.encode(keccak256("AlephTape.arena.v2"), a, b, uint256(7))));
        assertTrue(arena.matchSeed(a, b, 7) != arena.matchSeed(b, a, 7), "colours are part of the seed");
    }

    /// The arena's seed domain differs from the three games'.
    function test_A7d_seedDomainDiffersFromTheGames() public {
        bytes32 k = keccak256("k");
        bytes32 d = arena.SEED_DOMAIN();
        assertTrue(d != new AlephSnake(address(reg), k).SEED_DOMAIN());
        assertTrue(d != new AlephGame2048(address(reg), k, 6, 64).SEED_DOMAIN());
        assertTrue(d != new AlephFlappy(address(reg), k).SEED_DOMAIN());
    }

    // ------------------------------------------------------------------ A8: guards
    function test_A8_guards() public {
        ArenaGame memory G = _game(0);
        (bytes32 black, bytes32 white) = _sides(G);
        AlephGomokuArena.AiPly[] memory plies = _plies(0, G);
        vm.expectRevert(abi.encodeWithSelector(AlephGomokuArena.NotEntered.selector, black));
        arena.settleMatch(black, white, 0, G.moves, plies);
        _enterBoth();
        vm.expectRevert(AlephGomokuArena.SameEntrant.selector);
        arena.settleMatch(black, black, 0, G.moves, plies);
        vm.expectRevert(AlephGomokuArena.PlyCount.selector);
        arena.settleMatch(black, white, 0, G.moves, new AlephGomokuArena.AiPly[](3));
        vm.expectRevert(AlephGomokuArena.PlyCount.selector);
        arena.settleMatch(black, white, 0, hex"14", new AlephGomokuArena.AiPly[](0));
        uint256 nonce = _nonceFor(G);
        // unfinished record
        bytes memory cut = new bytes(G.n - 1);
        for (uint256 i; i < cut.length; ++i) cut[i] = G.moves[i];
        AlephGomokuArena.AiPly[] memory cutPlies = new AlephGomokuArena.AiPly[](cut.length - 2);
        for (uint256 i; i < cutPlies.length; ++i) cutPlies[i] = plies[i];
        vm.prank(SENDER);
        vm.expectRevert(AlephGomokuArena.NotFinished.selector);
        arena.settleMatch(black, white, nonce, cut, cutPlies);
        // a move after the five
        bytes memory more = bytes.concat(G.moves, hex"00");
        if (uint8(G.moves[0]) == 0) more[G.n] = 0x01;
        AlephGomokuArena.AiPly[] memory morePlies = new AlephGomokuArena.AiPly[](G.n - 1);
        for (uint256 i; i < plies.length; ++i) morePlies[i] = plies[i];
        vm.prank(SENDER);
        vm.expectRevert(abi.encodeWithSelector(AlephGomokuArena.MovesAfterEnd.selector, G.n));
        arena.settleMatch(black, white, nonce, more, morePlies);
    }

    // ------------------------------------------------------------------ A9: Elo
    function test_A9_eloMath() public view {
        assertEq(arena.expectedScore(0), 500);
        assertEq(arena.expectedScore(400), 909);
        assertEq(arena.expectedScore(-400), 91);
        assertEq(arena.expectedScore(25), 535); // 500 + (571 - 500) * 25 / 50
        assertEq(arena.expectedScore(800), 990);
        assertEq(arena.expectedScore(5000), 990); // clamped
        assertEq(arena.expectedScore(-5000), 10);
        assertEq(arena.eloDelta(1200, 1200, 1), 16);
        assertEq(arena.eloDelta(1200, 1200, 2), -16);
        assertEq(arena.eloDelta(1200, 1200, 3), 0);
        assertEq(arena.eloDelta(1400, 1200, 1), 8); // 32 * (1000 - 760) / 1000 = 7.68
        assertEq(arena.eloDelta(1400, 1200, 2), -24); // 32 * (0 - 760) / 1000 = -24.32
        assertEq(arena.eloDelta(1200, 1400, 3), 8); // 32 * (500 - 240) / 1000 = 8.32
        assertEq(arena.eloDelta(2400, 1200, 1), 0); // 32 * 10 / 1000 = 0.32
        for (int256 d = -900; d <= 900; d += 37) {
            assertEq(arena.expectedScore(d) + arena.expectedScore(-d), 1000, "symmetric");
        }
    }

    function test_A9b_eloAppliedAfterMatch() public {
        _enterBoth();
        ArenaGame memory G = _game(0);
        (bytes32 black, bytes32 white) = _sides(G);
        uint8 r = _settle(0);
        int32 d = r == 1 ? int32(16) : (r == 2 ? int32(-16) : int32(0));
        assertEq(arena.entrant(black).elo, 1200 + d);
        assertEq(arena.entrant(white).elo, 1200 - d);
    }

    // ------------------------------------------------------------------ A10: gas, long match, real registry costs
    function test_A10_longMatchGas() public {
        // verifiers that burn 210k like the real GomokuGroth16Verifier
        bytes32 a = reg.register(address(proc), 15, new AlephRegistry.CircuitRef[](0), address(new TruthVerifier(210_000)));
        bytes32 b = reg.register(address(proc), 15, new AlephRegistry.CircuitRef[](0), address(new TruthVerifier(210_000)));
        keyA = a;
        keyB = b;
        _enterBoth();
        // the fixture's longest game (81-ply draw when present)
        uint256 best;
        uint256 bestN;
        for (uint256 g; g < 6; ++g) {
            uint256 n = _game(g).n;
            if (n > bestN) (best, bestN) = (g, n);
        }
        ArenaGame memory G = _game(best);
        (bytes32 black, bytes32 white) = _sides(G);
        uint256 nonce = _nonceFor(G);
        AlephGomokuArena.AiPly[] memory plies = _plies(best, G);
        uint256 net;
        for (uint256 j; j < plies.length; ++j) if (plies[j].y.length != 0) net++;
        uint256 limit = 600_000 * net + 400_000;
        (uint8 r, uint256 used) = _measuredSettle(limit, black, white, nonce, G.moves, plies);
        assertEq(r, G.result);
        emit log_named_uint("plies", G.n);
        emit log_named_uint("network plies verified (verifier burns 210k)", net);
        emit log_named_uint("settleMatch gas", used);
        emit log_named_uint("per verified ply (avg)", used / net);
        assertLt(used, limit);
    }
}
