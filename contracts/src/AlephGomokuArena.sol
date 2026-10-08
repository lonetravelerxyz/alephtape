// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AlephRegistry} from "./AlephRegistry.sol";
import {GomokuRules} from "./GomokuRules.sol";

/// @title AlephGomokuArena — permissionless AI-vs-AI gomoku tournament, every move ZK-proven
/// @notice An "AI player" is any circuit registered in AlephRegistry (so: taped out on an allowed processor, ℵ₀) with
///         the gomoku interface — nIn 162, nOut 486, the AlephGomoku encoding and selection rule. Anyone can `enter`
///         one. `settleMatch` replays a whole AI-vs-AI game in one transaction: the first two plies come from the
///         match seed, every later ply must be the move the side to move's own circuit picks, checked exactly like
///         AlephGomoku (rules 1–4 on the board, no proof; rule 5 = argmax of that circuit's proven scores, from the
///         registry cache or a `verifyEval` in the same call). Results update Elo (K = 32) and W/D/L. No funds.
/// @dev    x is always encoded from the mover's perspective: own stones in bits 0..80, the opponent's in 81..161.
///         seed = keccak256(abi.encode(SEED_DOMAIN, black, white, nonce)), bound to no address: each seed settles
///         once, globally (first settle wins), and MatchSettled names msg.sender as the settler.
///         Opening: cells i0 = seed % 25 and i1 = (seed >> 128) % 24 (+1 if >= i0) of the central 5×5
///         (rows/cols 2..6, cell (2 + i / 5) * 9 + 2 + i % 5); black plays i0, white i1.
///         Gas: send 600k × (network plies not yet cached) + 25k × plies + 400k explicitly; never eth_estimateGas (the registry
///         reverts InsufficientGas below ~520k left at a verify).
contract AlephGomokuArena {
    struct AiPly {
        bytes y;
        uint256[24] proof;
    }

    struct Entrant {
        address owner;
        int32 elo;
        uint32 wins;
        uint32 draws;
        uint32 losses;
        uint64 enteredAt;
        string name;
    }

    error UnknownCircuit();
    error WrongInterface(uint32 nIn, uint32 nOut);
    error AlreadyEntered();
    error BadName();
    error NotEntered(bytes32 key);
    error SameEntrant();
    error AlreadySettled();
    error PlyCount();
    error BadOpening(uint256 ply);
    error IllegalMove(uint256 ply);
    error WrongMove(uint256 ply);
    error MovesAfterEnd(uint256 ply);
    error NotFinished();
    error MissingProof(uint256 ply);
    error ProofRejected(uint256 ply); // registry returned false (the real AlephRegistry reverts InvalidProof instead)

    event Entered(bytes32 indexed key, address indexed owner, string name);
    event MatchSettled(
        bytes32 indexed black, bytes32 indexed white, address indexed settler, bytes32 seed, uint8 result, uint16 nMoves
    );
    event EloUpdated(bytes32 indexed key, int32 elo, int32 delta);

    uint8 public constant BLACK_WIN = 1;
    uint8 public constant WHITE_WIN = 2;
    uint8 public constant DRAW = 3;
    uint32 public constant N_IN = 162;
    uint32 public constant N_OUT = 486;
    int32 public constant INITIAL_ELO = 1200;
    int256 public constant K = 32;
    uint256 public constant MAX_NAME_BYTES = 32;
    /// Seed domain tag: seed = keccak256(abi.encode(SEED_DOMAIN, black, white, nonce)). Separates arena seeds from
    /// the other games' (snake / 2048 / flappy).
    bytes32 public constant SEED_DOMAIN = keccak256("AlephTape.arena.v2");

    uint256 internal constant CELLS = 81;
    /// Expected score in per-mille for rating difference d = 0, 50, …, 800 (1000 / (1 + 10^(-d/400)), rounded),
    /// 10 bits each, entry i at bits [10i, 10i + 10): 500 571 640 703 760 808 849 882 909 930 947 960 969 977 983 987 990.
    uint256 internal constant ELO_TABLE = 0x3def6fd7f47c9f03b3e8b8ddcb51ca2f8afe808edf4;

    AlephRegistry public immutable registry;
    mapping(bytes32 => Entrant) internal entrants_;
    bytes32[] public keys; // entry order
    mapping(bytes32 => bool) public settled; // seed => settled

    constructor(address registry_) {
        registry = AlephRegistry(registry_);
    }

    // ------------------------------------------------------------------ entry (permissionless)
    /// @notice Enter a registered circuit with the gomoku interface as an AI player; msg.sender becomes its owner.
    function enter(bytes32 circuitKey, string calldata name) external {
        if (entrants_[circuitKey].owner != address(0)) revert AlreadyEntered();
        uint256 len = bytes(name).length;
        if (len == 0 || len > MAX_NAME_BYTES) revert BadName();
        AlephRegistry.Circuit memory c = registry.circuit(circuitKey);
        if (c.verifier == address(0)) revert UnknownCircuit();
        if (c.nIn != N_IN || c.nOut != N_OUT) revert WrongInterface(c.nIn, c.nOut);
        entrants_[circuitKey] = Entrant({
            owner: msg.sender,
            elo: INITIAL_ELO,
            wins: 0,
            draws: 0,
            losses: 0,
            enteredAt: uint64(block.timestamp),
            name: name
        });
        keys.push(circuitKey);
        emit Entered(circuitKey, msg.sender, name);
    }

    // ------------------------------------------------------------------ settle
    /// @param nonce the match's nonce: seed = matchSeed(black, white, nonce), bound to no address; each seed settles once,
    ///        globally (first settle wins), whoever sends it.
    /// @param moves the whole record, one byte per ply (0..80): plies 0 and 1 are the seed's opening, then black
    ///        (black's circuit) on even plies and white on odd plies.
    /// @param plies one per ply from ply 2 (plies[j] ↔ ply j + 2); ignored on rule plies, may be empty when cached.
    /// @return result 1 black wins, 2 white wins, 3 draw
    function settleMatch(bytes32 black, bytes32 white, uint256 nonce, bytes calldata moves, AiPly[] calldata plies)
        external
        returns (uint8 result)
    {
        if (black == white) revert SameEntrant();
        if (entrants_[black].owner == address(0)) revert NotEntered(black);
        if (entrants_[white].owner == address(0)) revert NotEntered(white);
        uint256 n = moves.length;
        if (n < 2 || plies.length != n - 2) revert PlyCount();
        bytes32 seed = matchSeed(black, white, nonce);
        if (settled[seed]) revert AlreadySettled();

        result = _replay(seed, [black, white], moves, plies);

        settled[seed] = true;
        _rate(black, white, result);
        // forge-lint: disable-next-line(unsafe-typecast)
        emit MatchSettled(black, white, msg.sender, seed, result, uint16(n)); // n <= 81 once the replay succeeded
    }

    // ------------------------------------------------------------------ views (web / scripts)
    /// @notice The seed of a match: keccak256(abi.encode(SEED_DOMAIN, black, white, nonce)). Not bound to an address.
    function matchSeed(bytes32 black, bytes32 white, uint256 nonce) public pure returns (bytes32) {
        return keccak256(abi.encode(SEED_DOMAIN, black, white, nonce));
    }

    /// @notice The two opening cells (black's, white's) a seed fixes.
    function opening(bytes32 seed) public pure returns (uint8 blackCell, uint8 whiteCell) {
        uint256 i0 = uint256(seed) % 25;
        uint256 i1 = (uint256(seed) >> 128) % 24;
        if (i1 >= i0) i1 += 1;
        blackCell = _central(i0);
        whiteCell = _central(i1);
    }

    function entrant(bytes32 key) external view returns (Entrant memory) {
        return entrants_[key];
    }

    function entrantCount() external view returns (uint256) {
        return keys.length;
    }

    /// @notice Entrants in entry order, `count` from `start` (clamped).
    function entrantsPage(uint256 start, uint256 count) external view returns (bytes32[] memory ks, Entrant[] memory es) {
        uint256 end = start + count;
        if (end > keys.length) end = keys.length;
        if (start > end) start = end;
        ks = new bytes32[](end - start);
        es = new Entrant[](end - start);
        for (uint256 i = start; i < end; ++i) {
            ks[i - start] = keys[i];
            es[i - start] = entrants_[keys[i]];
        }
    }

    /// @notice Expected score of a player rated `d` above the opponent, per mille (table + linear interpolation,
    ///         |d| clamped to 800).
    function expectedScore(int256 d) public pure returns (int256) {
        bool neg = d < 0;
        uint256 a = uint256(neg ? -d : d);
        if (a > 800) a = 800;
        uint256 i = a / 50;
        uint256 lo = (ELO_TABLE >> (10 * i)) & 1023;
        uint256 e = lo;
        if (i < 16) e = lo + (((ELO_TABLE >> (10 * (i + 1))) & 1023) - lo) * (a % 50) / 50;
        // forge-lint: disable-next-line(unsafe-typecast)
        return neg ? 1000 - int256(e) : int256(e); // e <= 990
    }

    /// @notice Black's Elo change for a result (white's is the negative: every update is zero-sum).
    function eloDelta(int256 rBlack, int256 rWhite, uint8 result) public pure returns (int256) {
        int256 s = result == BLACK_WIN ? int256(1000) : (result == DRAW ? int256(500) : int256(0));
        int256 num = K * (s - expectedScore(rBlack - rWhite));
        return num >= 0 ? (num + 500) / 1000 : -((-num + 500) / 1000); // round half away from zero
    }

    // ------------------------------------------------------------------ internals
    function _replay(bytes32 seed, bytes32[2] memory sides, bytes calldata moves, AiPly[] calldata plies)
        internal
        returns (uint8 result)
    {
        (uint8 o0, uint8 o1) = opening(seed);
        uint256[2] memory stones; // [black, white] bitboards
        uint256 n = moves.length;
        for (uint256 ply; ply < n; ++ply) {
            if (result != 0) revert MovesAfterEnd(ply);
            uint256 m = uint8(moves[ply]);
            if (m >= CELLS) revert IllegalMove(ply);
            // forge-lint: disable-next-line(incorrect-shift)
            uint256 bit = 1 << m;
            if ((stones[0] | stones[1]) & bit != 0) revert IllegalMove(ply);
            uint256 side = ply & 1;
            if (ply < 2) {
                if (m != (ply == 0 ? o0 : o1)) revert BadOpening(ply);
            } else if (_move(sides[side], stones[side], stones[side ^ 1], plies[ply - 2], ply) != m) {
                revert WrongMove(ply);
            }
            stones[side] |= bit;
            if (GomokuRules.hasFive(stones[side])) result = side == 0 ? BLACK_WIN : WHITE_WIN;
            else if (ply == CELLS - 1) result = DRAW;
        }
        if (result == 0) revert NotFinished();
    }

    /// The move the side to move (circuit `key`, stones `own`) must play: rules 1–4 on the board, else rule 5 on
    /// its proven scores.
    function _move(bytes32 key, uint256 own, uint256 opp, AiPly calldata p, uint256 ply) internal returns (uint256 want) {
        want = GomokuRules.ruleMove(own, opp);
        if (want == GomokuRules.NO_RULE) want = GomokuRules.argmax(own | opp, _provenScores(key, own, opp, p, ply));
    }

    function _provenScores(bytes32 key, uint256 own, uint256 opp, AiPly calldata p, uint256 ply)
        internal
        returns (bytes memory y)
    {
        bytes memory x = GomokuRules.encodeX(own, opp);
        bool proven;
        (proven, y) = registry.getResult(key, x);
        if (!proven) {
            if (p.y.length == 0) revert MissingProof(ply);
            if (!registry.verifyEval(key, x, p.y, p.proof)) revert ProofRejected(ply);
            y = p.y;
        }
    }

    function _rate(bytes32 black, bytes32 white, uint8 result) internal {
        Entrant storage b = entrants_[black];
        Entrant storage w = entrants_[white];
        int256 d = eloDelta(b.elo, w.elo, result);
        // forge-lint: disable-next-line(unsafe-typecast)
        int32 d32 = int32(d); // |d| <= 32
        b.elo += d32;
        w.elo -= d32;
        if (result == BLACK_WIN) {
            b.wins += 1;
            w.losses += 1;
        } else if (result == WHITE_WIN) {
            w.wins += 1;
            b.losses += 1;
        } else {
            b.draws += 1;
            w.draws += 1;
        }
        emit EloUpdated(black, b.elo, d32);
        emit EloUpdated(white, w.elo, -d32);
    }

    function _central(uint256 i) internal pure returns (uint8) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8((2 + i / 5) * 9 + 2 + i % 5); // i < 25 -> 20..60
    }
}
