// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAlephEval} from "./AlephGomoku.sol";

/// @title AlephSnake — on-chain replay and scoring of an 8×8 snake sprint whose every turn is chosen by a ZK-proven
///        TapeOut circuit
/// @notice The run is played off-chain (the browser simulates the same folded netlist); one `settle` replays it with
///         the deterministic food and checks every move: each action must be the selection rule's pick over the
///         circuit's proven scores (registry cache, otherwise `verifyEval`). A move where only one action survives
///         is a "rule move": it is checked from the board alone and needs no proof. Holds no funds.
/// @dev    Rules (byte-identical with the off-chain game and prover):
///         board 8×8, cell = r*8 + c, r downwards; directions 0 up, 1 right, 2 down, 3 left. Start: tail 26, body 27,
///         head 28, heading right. seed = keccak256(abi.encode(SEED_DOMAIN, nonce)), not bound to any address: whoever
///         settles a seed first is credited. Food i goes to the k-th empty cell
///         (ascending), k = uint256(keccak256(abi.encode(seed, i))) % empties. Actions: 0 straight, 1 left, 2 right.
///         Death = off the board or into the snake except its tail. Eating grows by one. The run ends on death (the
///         fatal move counts), after N_MAX moves, or when the board is full. Score = food eaten.
///         x (64 bits, 8 bytes LE): bits 0..47 = the 7×7 egocentric window (f = 3..-3, r = -3..3, head skipped;
///         1 = off board or snake except head and tail), bits 48..55 / 56..63 = thermometers [d >= t] of the food's
///         forward / right offset, t in (-5, -3, -1, 0, 1, 2, 4, 6). Bits 17 / 23 / 24 = straight / left / right dies.
///         y (21 bits, 3 bytes LE): score of action a in bits [7a, 7a+7).
///         Gas: the registry reverts InsufficientGas when < 520k is left at a verify, so send the explicit gas limit
///         gasLimitFor(moves, positions to verify). Never use eth_estimateGas.
contract AlephSnake {
    struct AiPly {
        bytes y;
        uint256[24] proof;
    }

    /// Replay state (memory). ring: snake cells, tail at ring[tail % 128], head at ring[head % 128].
    /// pad[d]: the snake on a 16×16 board with walls, rotated so that heading d points up (the view's frame).
    struct Run {
        bytes32 seed;
        uint256 occ; // snake cells (bitboard, bits 0..63)
        uint256[4] pad;
        uint256 tail; // ring index of the tail
        uint256 head; // ring index of the head
        uint256 dir;
        uint256 food; // cell, or 64 when the board is full
        uint256 foodIndex;
        uint256 score;
        bool ended;
        uint8[128] ring;
    }

    error BadAction(uint256 move);
    error WrongAction(uint256 move);
    error NotFinished();
    error MovesAfterEnd(uint256 move);
    error AlreadySettled();
    error PlyCount();
    error MissingProof(uint256 move);
    error ProofRejected(uint256 move); // registry returned false (the real AlephRegistry reverts InvalidProof instead)
    error BadInput(); // select / needsProof: wrong x / y length or non-canonical y

    event RunSettled(address indexed player, bytes32 indexed seed, uint256 score, uint256 moves);

    uint256 public constant N_MAX = 24;
    /// Seed domain tag: seed = keccak256(abi.encode(SEED_DOMAIN, nonce)). Separates snake seeds from the other games'.
    bytes32 public constant SEED_DOMAIN = keccak256("AlephTape.snake.v2");
    /// Explicit gas limit for settle (gasLimitFor): VERIFY_GAS_PER_MOVE per distinct position to verify (Groth16 verifier
    /// ~200k + registry cache write + calldata) + GAS_PER_MOVE per move (replay, cache read) + BASE_GAS (tx, the
    /// registry's 520k reserve). Measured (forge, verifier burning 210k): 24 moves / 24 verified 7.1M, all cached 0.6M.
    uint256 public constant VERIFY_GAS_PER_MOVE = 290_000;
    uint256 public constant GAS_PER_MOVE = 30_000;
    uint256 public constant BASE_GAS = 700_000;

    uint256 internal constant CELLS = 64;
    uint256 internal constant SAFE_STRAIGHT = 17;
    uint256 internal constant SAFE_LEFT = 23;
    uint256 internal constant SAFE_RIGHT = 24;
    /// 16×16 bitboard (bit = row*16 + col) with every cell outside rows/cols 4..11 set: the board's surroundings.
    uint256 internal constant WALLS = 0xfffffffffffffffff00ff00ff00ff00ff00ff00ff00ff00fffffffffffffffff;

    address public immutable registry;
    bytes32 public immutable circuitKey;
    mapping(address => uint256) public bestScore;
    mapping(bytes32 => bool) public settled; // seed => settled

    constructor(address registry_, bytes32 circuitKey_) {
        registry = registry_;
        circuitKey = circuitKey_;
    }

    // ------------------------------------------------------------------ settle
    /// @param nonce   the run's nonce: seed = seedOf(nonce), bound to no address; each seed settles once, globally
    ///                (first settle wins) and credits msg.sender.
    /// @param actions one byte per move (0 straight, 1 left, 2 right), until death, N_MAX or a full board.
    /// @param plies   one per move: plies[m] is ignored for rule moves (it may be empty) and may be empty when the
    ///                position is cached in the registry; otherwise y + the 24-word proof for verifyEval.
    /// @return score  food eaten
    function settle(uint256 nonce, bytes calldata actions, AiPly[] calldata plies) external returns (uint256 score) {
        uint256 n = actions.length;
        if (plies.length != n) revert PlyCount();
        bytes32 seed = seedOf(nonce);
        if (settled[seed]) revert AlreadySettled();

        Run memory s = _start(seed);
        for (uint256 m; m < n; ++m) {
            if (s.ended) revert MovesAfterEnd(m);
            uint256 a = uint8(actions[m]);
            if (a > 2) revert BadAction(m);
            uint256 x = _x(s);
            uint256 want = _ruleAction(x);
            if (want == 3) want = _best(x, _provenScores(x, plies[m], m));
            if (want != a) revert WrongAction(m);
            _step(s, a);
            if (m + 1 == N_MAX) s.ended = true;
        }
        if (!s.ended) revert NotFinished();

        settled[seed] = true;
        score = s.score;
        if (score > bestScore[msg.sender]) bestScore[msg.sender] = score;
        emit RunSettled(msg.sender, seed, score, n);
    }

    // ------------------------------------------------------------------ helpers for the web / reference vectors
    /// @notice The action for view x given circuit scores y (same rule as the prover and the browser).
    function select(bytes calldata x, bytes calldata y) external pure returns (uint8) {
        uint256 xv = _decodeX(x);
        uint256 r = _ruleAction(xv);
        if (r == 3) r = _best(xv, _decodeY(y));
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(r); // < 3
    }

    /// @notice True iff the scores decide the move at view x (0 or >= 2 safe actions): settle needs a proof or a
    ///         registry cache hit for it. False: exactly one action survives, settle checks it from x alone.
    function needsProof(bytes calldata x) external pure returns (bool) {
        return _ruleAction(_decodeX(x)) == 3;
    }

    /// @notice The explicit gas limit to send with settle: `moves` actions, `toVerify` distinct positions that need a
    ///         proof and are not cached in the registry yet. Never use eth_estimateGas (see the contract notes).
    function gasLimitFor(uint256 moves, uint256 toVerify) external pure returns (uint256) {
        return VERIFY_GAS_PER_MOVE * toVerify + GAS_PER_MOVE * moves + BASE_GAS;
    }

    /// @notice The seed of a run: keccak256(abi.encode(SEED_DOMAIN, nonce)). Not bound to an address.
    function seedOf(uint256 nonce) public pure returns (bytes32) {
        return keccak256(abi.encode(SEED_DOMAIN, nonce));
    }

    // ------------------------------------------------------------------ replay
    function _start(bytes32 seed) internal pure returns (Run memory s) {
        s.seed = seed;
        s.ring[0] = 26;
        s.ring[1] = 27;
        s.ring[2] = 28;
        s.tail = 0;
        s.head = 2;
        s.occ = (1 << 26) | (1 << 27) | (1 << 28);
        for (uint256 d; d < 4; ++d) {
            s.pad[d] = WALLS | _padBit(26, d) | _padBit(27, d) | _padBit(28, d);
        }
        s.dir = 1;
        s.food = _spawn(s.seed, 0, s.occ, 3);
    }

    /// (row, col) of cell in the frame where heading d points up and its right points right.
    function _rot(uint256 cell, uint256 d) internal pure returns (uint256, uint256) {
        uint256 r = cell >> 3;
        uint256 c = cell & 7;
        if (d == 0) return (r, c);
        if (d == 1) return (7 - c, r);
        if (d == 2) return (7 - r, 7 - c);
        return (c, 7 - r);
    }

    function _padBit(uint256 cell, uint256 d) internal pure returns (uint256) {
        (uint256 r, uint256 c) = _rot(cell, d);
        return uint256(1) << ((r + 4) * 16 + c + 4);
    }

    function _occupy(Run memory s, uint256 cell, bool on) internal pure {
        if (on) s.occ |= uint256(1) << cell;
        else s.occ &= ~(uint256(1) << cell);
        for (uint256 d; d < 4; ++d) {
            uint256 b = _padBit(cell, d);
            s.pad[d] = on ? s.pad[d] | b : s.pad[d] & ~b;
        }
    }

    /// Food i: the k-th empty cell in ascending order, k = keccak256(abi.encode(seed, i)) % empties; 64 if none.
    function _spawn(bytes32 seed, uint256 i, uint256 occ, uint256 len) internal pure returns (uint256) {
        uint256 empties = CELLS - len;
        if (empties == 0) return CELLS;
        uint256 k = uint256(keccak256(abi.encode(seed, i))) % empties;
        for (uint256 c; c < CELLS; ++c) {
            if ((occ >> c) & 1 == 0) {
                if (k == 0) return c;
                --k;
            }
        }
        return CELLS; // unreachable
    }

    function _step(Run memory s, uint256 a) internal pure {
        uint256 d = a == 0 ? s.dir : (a == 1 ? (s.dir + 3) & 3 : (s.dir + 1) & 3);
        s.dir = d;
        uint256 h = s.ring[s.head & 127];
        (bool ok, uint256 nh) = _next(h, d);
        uint256 tailCell = s.ring[s.tail & 127];
        if (!ok || ((s.occ >> nh) & 1 == 1 && nh != tailCell)) {
            s.ended = true; // death
            return;
        }
        ++s.head;
        // forge-lint: disable-next-line(unsafe-typecast)
        s.ring[s.head & 127] = uint8(nh); // < 64
        if (nh == s.food) {
            _occupy(s, nh, true);
            ++s.score;
            ++s.foodIndex;
            s.food = _spawn(s.seed, s.foodIndex, s.occ, s.head - s.tail + 1);
            if (s.food == CELLS) s.ended = true; // board full
        } else {
            _occupy(s, tailCell, false);
            ++s.tail;
            _occupy(s, nh, true);
        }
    }

    function _next(uint256 cell, uint256 d) internal pure returns (bool ok, uint256 nc) {
        uint256 r = cell >> 3;
        uint256 c = cell & 7;
        if (d == 0) {
            if (r == 0) return (false, 0);
            return (true, cell - 8);
        }
        if (d == 1) {
            if (c == 7) return (false, 0);
            return (true, cell + 1);
        }
        if (d == 2) {
            if (r == 7) return (false, 0);
            return (true, cell + 8);
        }
        if (c == 0) return (false, 0);
        return (true, cell - 1);
    }

    /// The 64-bit egocentric view (see the contract notes), as an integer with bit k = x bit k. In the rotated padded
    /// board the 7×7 window is 7 runs of 7 bits: window row i (f = 3 - i) is padded row hr + 1 + i, cols hc + 1 ..
    /// hc + 7; the head (bit 24 of the 49) is dropped.
    function _x(Run memory s) internal pure returns (uint256 x) {
        uint256 d = s.dir;
        uint256 h = s.ring[s.head & 127];
        uint256 p = s.pad[d] & ~_padBit(h, d) & ~_padBit(s.ring[s.tail & 127], d); // tail moves away: free
        (uint256 hr, uint256 hc) = _rot(h, d);
        uint256 w;
        unchecked {
            for (uint256 i; i < 7; ++i) {
                w |= ((p >> ((hr + 1 + i) * 16 + hc + 1)) & 0x7f) << (7 * i);
            }
        }
        x = (w & 0xffffff) | ((w >> 25) << 24);
        (uint256 fr, uint256 fc) = _rot(s.food, d);
        // forge-lint: disable-next-line(unsafe-typecast)
        x |= _thermo(int256(hr) - int256(fr)) << 48; // forward offset: rows decrease forwards
        // forge-lint: disable-next-line(unsafe-typecast)
        x |= _thermo(int256(fc) - int256(hc)) << 56; // right offset
    }

    /// [v >= t] for t in (-5, -3, -1, 0, 1, 2, 4, 6), bit j for the j-th threshold.
    function _thermo(int256 v) internal pure returns (uint256 b) {
        if (v >= -5) b |= 1;
        if (v >= -3) b |= 2;
        if (v >= -1) b |= 4;
        if (v >= 0) b |= 8;
        if (v >= 1) b |= 16;
        if (v >= 2) b |= 32;
        if (v >= 4) b |= 64;
        if (v >= 6) b |= 128;
    }

    /// The only safe action when exactly one survives; 3 when the scores decide (0, 2 or 3 safe actions).
    function _ruleAction(uint256 x) internal pure returns (uint256) {
        bool s0 = (x >> SAFE_STRAIGHT) & 1 == 0;
        bool s1 = (x >> SAFE_LEFT) & 1 == 0;
        bool s2 = (x >> SAFE_RIGHT) & 1 == 0;
        uint256 n = (s0 ? 1 : 0) + (s1 ? 1 : 0) + (s2 ? 1 : 0);
        if (n != 1) return 3;
        return s0 ? 0 : (s1 ? 1 : 2);
    }

    /// Highest score among the safe actions (all three when none is safe); ties to straight, left, right.
    function _best(uint256 x, uint256 y) internal pure returns (uint256 best) {
        uint256 mask = (((x >> SAFE_STRAIGHT) & 1) ^ 1) | ((((x >> SAFE_LEFT) & 1) ^ 1) << 1)
            | ((((x >> SAFE_RIGHT) & 1) ^ 1) << 2);
        if (mask == 0) mask = 7;
        uint256 bestPlus1; // best score + 1, so the first candidate always wins the comparison
        for (uint256 a; a < 3; ++a) {
            if ((mask >> a) & 1 == 0) continue;
            uint256 sc = ((y >> (7 * a)) & 127) + 1;
            if (sc > bestPlus1) {
                bestPlus1 = sc;
                best = a;
            }
        }
    }

    function _provenScores(uint256 x, AiPly calldata p, uint256 m) internal returns (uint256) {
        bytes memory xb = _encodeX(x);
        (bool proven, bytes memory y) = IAlephEval(registry).getResult(circuitKey, xb);
        if (!proven) {
            if (p.y.length == 0) revert MissingProof(m);
            if (!IAlephEval(registry).verifyEval(circuitKey, xb, p.y, p.proof)) revert ProofRejected(m);
            y = p.y;
        }
        if (y.length != 3) revert BadInput();
        return uint256(uint8(y[0])) | (uint256(uint8(y[1])) << 8) | (uint256(uint8(y[2])) << 16);
    }

    function _encodeX(uint256 x) internal pure returns (bytes memory b) {
        b = new bytes(8);
        for (uint256 i; i < 8; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            b[i] = bytes1(uint8(x >> (8 * i)));
        }
    }

    function _decodeX(bytes calldata x) internal pure returns (uint256 v) {
        if (x.length != 8) revert BadInput();
        for (uint256 i = 8; i > 0; --i) {
            v = (v << 8) | uint8(x[i - 1]);
        }
    }

    function _decodeY(bytes calldata y) internal pure returns (uint256 v) {
        if (y.length != 3 || uint8(y[2]) >> 5 != 0) revert BadInput();
        v = uint256(uint8(y[0])) | (uint256(uint8(y[1])) << 8) | (uint256(uint8(y[2])) << 16);
    }
}
