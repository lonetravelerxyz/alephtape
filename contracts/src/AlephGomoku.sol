// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GomokuRules} from "./GomokuRules.sol";

/// The two AlephRegistry entry points AlephGomoku needs.
interface IAlephEval {
    function getResult(bytes32 key, bytes calldata x) external view returns (bool proven, bytes memory y);
    function verifyEval(bytes32 key, bytes calldata x, bytes calldata y, uint256[24] calldata proof)
        external
        returns (bool);
}

/// @title AlephGomoku — stateless settlement of a 9×9 gomoku game against a ZK-proven BNN
/// @notice The game is played off-chain; one `settle` replays it. Every AI ply must be the move the selection
///         rule picks. Rules 1–4 (five, block five, open four, block open four) depend on the board alone and are
///         checked here directly; only rule-5 plies use the AI circuit's scores, so only they need a proof (or a
///         registry cache hit). The AI "brain" (a TapeOut circuit, ~100k+ gates) is thus enforced on-chain at
///         ~440k gas per new network position instead of a direct eval no block can hold.
///         Holds no funds; a human win earns a non-transferable badge count.
/// @dev    Board cell i = r*9 + c. Human = black, even plies; AI = white, odd plies. No forbidden moves.
///         x (162 bits, 21 bytes LE) = AI stones in bits 0..80, human stones in bits 81..161, board before the AI move.
///         y (486 bits, 61 bytes LE) = 81 scores, cell k in bits [6k, 6k+6), LSB first.
///         Gas: the registry reverts InsufficientGas when < 520k is left at a verify, so send an explicit gas limit
///         of 600k × (AI plies that need a proof and are not cached) + 400k. Never use eth_estimateGas.
contract AlephGomoku {
    struct AiPly {
        bytes y;
        uint256[24] proof;
    }

    error IllegalMove(uint256 ply);
    error WrongAiMove(uint256 ply);
    error NotFinished();
    error MovesAfterEnd(uint256 ply);
    error AlreadySettled();
    error PlyCount();
    error MissingProof(uint256 ply);
    error ProofRejected(uint256 ply); // registry returned false (the real AlephRegistry reverts InvalidProof instead)
    error BadInput(); // select(): wrong x / y length or an inconsistent board

    event GameSettled(address indexed player, bytes32 indexed recordHash, uint8 result, uint16 nMoves);

    uint8 internal constant HUMAN_WIN = 1;
    uint8 internal constant AI_WIN = 2;
    uint8 internal constant DRAW = 3;

    uint256 internal constant CELLS = 81;
    uint256 internal constant Y_BYTES = 61;
    uint256 internal constant BOARD = GomokuRules.BOARD;
    uint256 internal constant NO_RULE = GomokuRules.NO_RULE;

    address public immutable registry;
    bytes32 public immutable circuitKey;
    mapping(address => uint256) public badges; // human wins per player
    mapping(bytes32 => bool) public settled; // recordHash => settled

    constructor(address registry_, bytes32 circuitKey_) {
        registry = registry_;
        circuitKey = circuitKey_;
    }

    // ------------------------------------------------------------------ settle
    /// @param moves one byte per ply (0..80); plies[j] belongs to AI ply 2j+1. plies[j] is ignored when rules 1–4
    ///        decide that ply (it may be empty), and may be empty when the position is cached in the registry.
    /// @return result 1 human win, 2 AI win, 3 draw
    function settle(bytes calldata moves, AiPly[] calldata plies) external returns (uint8 result) {
        uint256 n = moves.length;
        if (plies.length != n / 2) revert PlyCount();
        bytes32 recordHash = keccak256(moves);
        if (settled[recordHash]) revert AlreadySettled();

        uint256 ai;
        uint256 hu;
        for (uint256 ply; ply < n; ++ply) {
            if (result != 0) revert MovesAfterEnd(ply);
            uint256 m = uint8(moves[ply]);
            if (m >= CELLS) revert IllegalMove(ply);
            // forge-lint: disable-next-line(incorrect-shift)
            uint256 bit = 1 << m;
            if ((ai | hu) & bit != 0) revert IllegalMove(ply);
            if (ply & 1 == 0) {
                hu |= bit;
                if (GomokuRules.hasFive(hu)) result = HUMAN_WIN;
            } else {
                // Rules 1–4 need no scores: no registry read, no proof. Only rule 5 reads a proven y.
                uint256 want = GomokuRules.ruleMove(ai, hu);
                if (want == NO_RULE) want = GomokuRules.argmax(ai | hu, _provenScores(ai, hu, plies[ply >> 1], ply));
                if (want != m) revert WrongAiMove(ply);
                ai |= bit;
                if (GomokuRules.hasFive(ai)) result = AI_WIN;
            }
            if (result == 0 && ply == CELLS - 1) result = DRAW;
        }
        if (result == 0) revert NotFinished();

        settled[recordHash] = true;
        if (result == HUMAN_WIN) badges[msg.sender] += 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        emit GameSettled(msg.sender, recordHash, result, uint16(n)); // n <= 81 once the replay succeeded
    }

    // ------------------------------------------------------------------ helpers for the web / reference vectors
    /// @notice The AI's move for board x given circuit scores y (same rule as the prover and the browser).
    function select(bytes calldata x, bytes calldata y) external pure returns (uint8) {
        if (y.length != Y_BYTES) revert BadInput();
        (uint256 ai, uint256 hu) = GomokuRules.decodeX(x);
        uint256 r = GomokuRules.ruleMove(ai, hu);
        if (r == NO_RULE) r = GomokuRules.argmax(ai | hu, y);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(r); // < 81
    }

    /// @notice True iff the AI ply at board x is decided by rule 5 (the circuit's scores): settle needs a proof or a
    ///         registry cache hit for it. False: rules 1–4 decide the ply and settle ignores its plies[j].
    function needsProof(bytes calldata x) external pure returns (bool) {
        (uint256 ai, uint256 hu) = GomokuRules.decodeX(x);
        return GomokuRules.ruleMove(ai, hu) == NO_RULE;
    }

    /// @notice x bytes for a board (AI and human bitboards, bits 0..80).
    function encodeX(uint256 ai, uint256 hu) external pure returns (bytes memory) {
        return GomokuRules.encodeX(ai & BOARD, hu & BOARD);
    }

    // ------------------------------------------------------------------ internals (rule code: GomokuRules)
    function _provenScores(uint256 ai, uint256 hu, AiPly calldata p, uint256 ply) internal returns (bytes memory y) {
        bytes memory x = GomokuRules.encodeX(ai, hu);
        bool proven;
        (proven, y) = IAlephEval(registry).getResult(circuitKey, x);
        if (!proven) {
            if (p.y.length == 0) revert MissingProof(ply);
            if (!IAlephEval(registry).verifyEval(circuitKey, x, p.y, p.proof)) revert ProofRejected(ply);
            y = p.y;
        }
    }
}
