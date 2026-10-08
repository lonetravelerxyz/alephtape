// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAlephEval} from "./AlephGomoku.sol";

/// @title AlephFlappy — on-chain replay of an ℵ Flappy (像素小鸟) sprint flown by a ZK-proven BNN
/// @notice The run is flown off-chain; one `settle` replays it. Every tick the AI looks at the 8×8 screen (x, 64 bits)
///         and its TapeOut circuit (the digit BNN's two neurons, new weights) outputs two scores (y, 14 bits). The
///         contract requires each recorded action to equal "flap iff s_flap > s_noflap" over scores that are proven
///         (registry cache, else verifyEval with a Groth16 proof). Pipes come from keccak of the run seed, so neither
///         the player nor the operator can choose them. Holds no funds.
/// @dev    Rules (identical in the off-chain game and prover):
///         8×8 screen, row 0 on top, the bird in column 1, starting in row 3. Pipe i is in screen column 8 + 4i - t
///         after t ticks and fills every row except its gap [g_i, g_i + 2]; raw_i = uint(keccak256(abi.encode(seed,
///         i))) % 6, g_0 = raw_0, g_i = raw_i clamped to [g_{i-1} - 3, g_{i-1} + 3]; seed = keccak256(abi.encode(
///         SEED_DOMAIN, nonce)), bound to no address. Tick: 1) flap -> y - 1, no flap -> y + 1; 2) scroll; 3) crash if y leaves 0..7 or hits a
///         pipe cell in column 1, else a pipe now in column 1 counts as passed (score + 1). A run ends on a crash
///         (that tick counts) or after N_MAX ticks.
///         x (8 bytes LE): bit 8r = bird in row r; bit 8r + c (c = 1..7) = pipe cell (r, c).
///         y (2 bytes LE): s_noflap = bits 0..6, s_flap = bits 7..13.
///         actions: bit t of `actions` (LE) = flap at tick t; length ceil(ticks / 8), unused high bits zero.
///         Gas: the registry reverts InsufficientGas when < 520k is left at a verify. Send an explicit gas limit of
///         GAS_PER_PROOF × (ticks that need a proof and are not cached) + GAS_BASE, never estimated.
contract AlephFlappy {
    struct AiPly {
        bytes y;
        uint256[24] proof;
    }

    error WrongAction(uint256 tick);
    error NotFinished();
    error TicksAfterCrash(uint256 tick);
    error AlreadySettled();
    error BadTicks();
    error BadActions();
    error MissingProof(uint256 tick);
    error ProofRejected(uint256 tick); // registry returned false (the real AlephRegistry reverts InvalidProof instead)
    error BadInput();

    event RunSettled(address indexed player, bytes32 indexed seed, uint8 score, uint8 ticks);

    uint256 public constant N_MAX = 32;
    /// Seed domain tag: seed = keccak256(abi.encode(SEED_DOMAIN, nonce)). Separates flappy seeds from the other games'.
    bytes32 public constant SEED_DOMAIN = keccak256("AlephTape.flappy.v2");
    uint256 public constant ROWS = 8;
    uint256 public constant BIRD_Y0 = 3;
    uint256 public constant N_PIPES = 8; // every pipe that can be on screen during N_MAX ticks
    uint256 internal constant FIRST_PIPE = 8; // pipe 0's screen column at t = 0
    uint256 internal constant GAP_TOPS = 6;
    uint256 internal constant MAX_STEP = 3;
    uint256 internal constant COL = 0x0101010101010101; // bit 8r of every row: one screen column
    uint256 internal constant GAP_ROWS = 0x010101; // three consecutive rows of one column
    /// Explicit gas-limit formula for settle (measured in AlephFlappy.t.sol F7).
    uint256 public constant GAS_PER_PROOF = 330_000;
    uint256 public constant GAS_BASE = 1_200_000;

    address public immutable registry;
    bytes32 public immutable circuitKey;
    mapping(address => uint256) public bestScore;
    mapping(bytes32 => bool) public settled; // seed => settled

    constructor(address registry_, bytes32 circuitKey_) {
        registry = registry_;
        circuitKey = circuitKey_;
    }

    // ------------------------------------------------------------------ settle
    /// @param nonce the run's nonce: seed = seedOf(nonce), bound to no address; each seed settles once, globally (first
    ///              settle wins) and credits msg.sender
    /// @param actions bit t = the AI flapped at tick t
    /// @param plies one per tick played; plies[t] may be empty when the screen is cached in the registry
    function settle(uint256 nonce, bytes calldata actions, AiPly[] calldata plies)
        external
        returns (uint8 score, uint8 ticks)
    {
        uint256 n = plies.length;
        if (n == 0 || n > N_MAX) revert BadTicks();
        if (actions.length != (n + 7) / 8) revert BadActions();
        if (n % 8 != 0 && uint8(actions[actions.length - 1]) >> (n % 8) != 0) revert BadActions();
        bytes32 seed = seedOf(nonce);
        if (settled[seed]) revert AlreadySettled();
        uint256 gp = _gaps(seed);

        uint256 y = BIRD_Y0;
        uint256 s;
        bool crashed;
        for (uint256 t; t < n; ++t) {
            if (crashed) revert TicksAfterCrash(t);
            bool flap = _decide(_provenScores(_encodeX(_screen(gp, t, y)), plies[t], t));
            if (flap != ((uint8(actions[t >> 3]) >> (t & 7)) & 1 == 1)) revert WrongAction(t);
            bool passed;
            (y, crashed, passed) = _step(gp, t, y, flap);
            if (passed) ++s;
        }
        if (!crashed && n != N_MAX) revert NotFinished();

        settled[seed] = true;
        if (s > bestScore[msg.sender]) bestScore[msg.sender] = s;
        // forge-lint: disable-next-line(unsafe-typecast)
        (score, ticks) = (uint8(s), uint8(n)); // s <= 7, n <= 32
        emit RunSettled(msg.sender, seed, score, ticks);
    }

    // ------------------------------------------------------------------ helpers for the web / tests
    /// @notice The seed of a run: keccak256(abi.encode(SEED_DOMAIN, nonce)). Not bound to an address.
    function seedOf(uint256 nonce) public pure returns (bytes32) {
        return keccak256(abi.encode(SEED_DOMAIN, nonce));
    }

    /// @notice The N_PIPES pipe gap tops of a run.
    function gaps(bytes32 seed) external pure returns (uint8[N_PIPES] memory g) {
        uint256 gp = _gaps(seed);
        for (uint256 i; i < N_PIPES; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            g[i] = uint8((gp >> (4 * i)) & 15);
        }
    }

    /// @notice x (8 bytes) the AI sees after t ticks with the bird in row y.
    function screen(bytes32 seed, uint256 t, uint256 y) external pure returns (bytes memory) {
        if (t >= N_MAX || y >= ROWS) revert BadInput();
        return _encodeX(_screen(_gaps(seed), t, y));
    }

    /// @notice The AI's action for circuit output y: flap iff s_flap > s_noflap (ties: no flap).
    function decide(bytes calldata y) external pure returns (bool) {
        return _decide(y);
    }

    // ------------------------------------------------------------------ internals
    /// Gap tops packed 4 bits each (pipe i in bits 4i..4i+3).
    function _gaps(bytes32 seed) internal pure returns (uint256 gp) {
        uint256 prev;
        for (uint256 i; i < N_PIPES; ++i) {
            uint256 g = uint256(keccak256(abi.encode(seed, i))) % GAP_TOPS;
            if (i != 0) {
                if (g > prev + MAX_STEP) g = prev + MAX_STEP;
                else if (g + MAX_STEP < prev) g = prev - MAX_STEP;
            }
            gp |= g << (4 * i);
            prev = g;
        }
    }

    /// x as a 64-bit word (bit 8r + c): bird marker in column 0, pipe cells in columns 1..7.
    function _screen(uint256 gp, uint256 t, uint256 y) internal pure returns (uint256 x) {
        // forge-lint: disable-next-line(incorrect-shift)
        x = 1 << (8 * y);
        // pipe i is in column c = 8 + 4i - t; visit the columns 1..7 that hold one
        for (uint256 c = 1; c < ROWS; ++c) {
            uint256 k = c + t;
            if (k < FIRST_PIPE || (k - FIRST_PIPE) % 4 != 0) continue;
            uint256 g = (gp >> (4 * ((k - FIRST_PIPE) / 4))) & 15;
            x |= (COL ^ (GAP_ROWS << (8 * g))) << c;
        }
    }

    /// One tick from row y after t ticks: (y', crashed, passed a pipe).
    function _step(uint256 gp, uint256 t, uint256 y, bool flap)
        internal
        pure
        returns (uint256 y2, bool crashed, bool passed)
    {
        if (flap) {
            if (y == 0) return (0, true, false);
            y2 = y - 1;
        } else {
            y2 = y + 1;
            if (y2 >= ROWS) return (y2, true, false);
        }
        uint256 k = t + 2; // column 1 after the scroll: 1 + (t + 1)
        if (k < FIRST_PIPE || (k - FIRST_PIPE) % 4 != 0) return (y2, false, false);
        uint256 g = (gp >> (4 * ((k - FIRST_PIPE) / 4))) & 15;
        if (y2 < g || y2 > g + 2) return (y2, true, false);
        return (y2, false, true);
    }

    function _encodeX(uint256 v) internal pure returns (bytes memory x) {
        x = new bytes(8);
        for (uint256 i; i < 8; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            x[i] = bytes1(uint8(v >> (8 * i)));
        }
    }

    function _decide(bytes memory y) internal pure returns (bool) {
        if (y.length != 2) revert BadInput();
        uint256 v = uint256(uint8(y[0])) | (uint256(uint8(y[1])) << 8);
        return (v >> 7) & 127 > v & 127;
    }

    function _provenScores(bytes memory x, AiPly calldata p, uint256 tick) internal returns (bytes memory y) {
        bool proven;
        (proven, y) = IAlephEval(registry).getResult(circuitKey, x);
        if (!proven) {
            if (p.y.length == 0) revert MissingProof(tick);
            if (!IAlephEval(registry).verifyEval(circuitKey, x, p.y, p.proof)) revert ProofRejected(tick);
            y = p.y;
        }
    }
}
