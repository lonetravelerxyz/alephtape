// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAlephEval} from "./AlephGomoku.sol";

/// @title AlephGame2048 — settle a 2048 sprint played by a ZK-proven BNN
/// @notice The AI only makes a Choice: one of four directions per move. The run is played off-chain; one `settle`
///         replays it from the nonce's seed (bound to no address), with deterministic spawns, and checks that every move is the
///         legal direction with the highest proven circuit score (registry cache hit, else `verifyEval`). Records
///         the score for msg.sender; each seed settles once, globally (first settle wins); holds no funds.
/// @dev    Board: packed uint64, cell i = r*4 + c (r = 0 top) in bits [4i, 4i+4) holds an exponent (tile 2^e, 0 empty).
///         Directions 0 Up, 1 Right, 2 Down, 3 Left. Standard 2048 slide/merge; score = sum of merged tile values.
///         seed = keccak256(abi.encode(SEED_DOMAIN, nonce)); spawn t (0, 1 = initial tiles, m + 2 after move m) uses
///         r = uint256(keccak256(abi.encode(seed, t))): the r % |empty|-th empty cell in index order, a 4 iff
///         (r >> 128) % 10 == 0, else a 2.
///         x (192 bits, 24 bytes LE) = cell i one-hot over 12 levels, bit 12i + min(e, 11). y = 4 scores of S bits,
///         direction d in bits [S*d, S*d + S), LE bytes. Select: the legal direction with the max score, ties to the
///         lowest index (U, R, D, L). A run ends after nMax moves or when no move is legal.
///         Gas: the registry reverts InsufficientGas when < 520k is left at a verify; send an explicit gas limit
///         (measured: 300k per move to verify + 30k per move + 600k). Never use eth_estimateGas.
contract AlephGame2048 {
    struct AiPly {
        bytes y;
        uint256[24] proof;
    }

    error WrongMove(uint256 i); // moves[i] is not the selection over the proven scores
    error NotFinished(); // fewer than nMax moves and a legal move is left
    error TooManyMoves();
    error MovesAfterEnd(uint256 i); // no legal move at move i
    error AlreadySettled();
    error PlyCount();
    error MissingProof(uint256 i);
    error ProofRejected(uint256 i); // registry returned false (the real AlephRegistry reverts InvalidProof instead)
    error BadInput(); // select(): wrong x / y length, non one-hot x, or no legal move

    event RunSettled(address indexed player, bytes32 indexed seed, uint256 score, uint256 maxTile, uint16 nMoves);

    /// Seed domain tag: seed = keccak256(abi.encode(SEED_DOMAIN, nonce)). Separates 2048 seeds from the other games'.
    bytes32 public constant SEED_DOMAIN = keccak256("AlephTape.game2048.v2");
    uint256 internal constant CELLS = 16;
    uint256 internal constant LEVELS = 12;
    uint256 internal constant X_BYTES = 24;

    address public immutable registry;
    bytes32 public immutable circuitKey;
    uint256 public immutable scoreBits; // S: bits per direction score in y
    uint256 public immutable nMax; // moves per sprint
    mapping(address => uint256) public bestScore;
    mapping(bytes32 => bool) public settled; // seed => settled

    constructor(address registry_, bytes32 circuitKey_, uint256 scoreBits_, uint256 nMax_) {
        require(scoreBits_ >= 1 && scoreBits_ <= 8 && nMax_ >= 1 && nMax_ <= 1000, "params");
        registry = registry_;
        circuitKey = circuitKey_;
        scoreBits = scoreBits_;
        nMax = nMax_;
    }

    // ------------------------------------------------------------------ settle
    /// @param nonce  the run's chosen number; seed = seedOf(nonce), bound to no address; credits msg.sender
    /// @param moves  one byte per move (0..3)
    /// @param plies  plies[i] proves the scores for the board before move i; may be empty when the registry has them
    /// @return score the standard 2048 merge score of the run
    function settle(uint256 nonce, bytes calldata moves, AiPly[] calldata plies) external returns (uint256 score) {
        uint256 n = moves.length;
        if (n > nMax) revert TooManyMoves();
        if (plies.length != n) revert PlyCount();
        bytes32 seed = seedOf(nonce);
        if (settled[seed]) revert AlreadySettled();

        uint256 board = _initial(seed);
        for (uint256 i; i < n; ++i) {
            uint256 legal = _legal(board);
            if (legal == 0) revert MovesAfterEnd(i);
            uint256 want = _select(legal, _provenScores(board, plies[i], i));
            if (uint8(moves[i]) != want) revert WrongMove(i);
            (uint256 next, uint256 gained) = _move(board, want);
            score += gained;
            board = _spawn(next, seed, i + 2);
        }
        if (n < nMax && _legal(board) != 0) revert NotFinished();

        settled[seed] = true;
        if (score > bestScore[msg.sender]) bestScore[msg.sender] = score;
        // forge-lint: disable-next-line(unsafe-typecast)
        emit RunSettled(msg.sender, seed, score, _maxTile(board), uint16(n)); // n <= nMax <= 1000
    }

    // ------------------------------------------------------------------ helpers for the web / reference vectors
    /// @notice The seed of a run: keccak256(abi.encode(SEED_DOMAIN, nonce)). Not bound to an address.
    function seedOf(uint256 nonce) public pure returns (bytes32) {
        return keccak256(abi.encode(SEED_DOMAIN, nonce));
    }

    function initialBoard(bytes32 seed) external pure returns (uint64) {
        return uint64(_initial(seed));
    }

    /// @notice Apply `moves` from the seed's initial board (no AI check): the board, score and legal-direction mask
    ///         after them. Reverts MovesAfterEnd(i) when moves[i] is not legal.
    function play(bytes32 seed, bytes calldata moves)
        external
        pure
        returns (uint64 board, uint256 score, uint8 legalMask)
    {
        uint256 b = _initial(seed);
        for (uint256 i; i < moves.length; ++i) {
            uint256 d = uint8(moves[i]);
            if (d > 3 || (_legal(b) >> d) & 1 == 0) revert MovesAfterEnd(i);
            (uint256 next, uint256 gained) = _move(b, d);
            score += gained;
            b = _spawn(next, seed, i + 2);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint64(b), score, uint8(_legal(b)));
    }

    /// @notice The AI's direction for board x given circuit scores y (same rule as the prover and the browser).
    function select(bytes calldata x, bytes calldata y) external view returns (uint8) {
        if (y.length != (4 * scoreBits + 7) / 8) revert BadInput();
        uint256 legal = _legal(_decodeX(x));
        if (legal == 0) revert BadInput();
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(_select(legal, y));
    }

    function encodeX(uint64 board) external pure returns (bytes memory) {
        return _encodeX(board);
    }

    /// @notice Board after one move (no spawn), its merge score and whether it changed (= the move is legal).
    function move(uint64 board, uint8 dir) external pure returns (uint64 next, uint256 gained, bool changed) {
        (uint256 nb, uint256 g) = _move(board, dir & 3);
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint64(nb), g, nb != board);
    }

    /// @notice Legal-direction mask (bit d set = direction d changes the board).
    function legalMask(uint64 board) external pure returns (uint8) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(_legal(board));
    }

    // ------------------------------------------------------------------ internals: proofs
    function _provenScores(uint256 board, AiPly calldata p, uint256 i) internal returns (bytes memory y) {
        bytes memory x = _encodeX(board);
        bool proven;
        (proven, y) = IAlephEval(registry).getResult(circuitKey, x);
        if (!proven) {
            if (p.y.length == 0) revert MissingProof(i);
            if (!IAlephEval(registry).verifyEval(circuitKey, x, p.y, p.proof)) revert ProofRejected(i);
            y = p.y;
        }
    }

    /// Legal direction with the max score; ties to the lowest index. `legal` != 0.
    function _select(uint256 legal, bytes memory y) internal view returns (uint256 best) {
        uint256 s = scoreBits;
        if (y.length != (4 * s + 7) / 8) revert BadInput();
        uint256 v;
        for (uint256 k = y.length; k > 0; --k) {
            v = (v << 8) | uint8(y[k - 1]);
        }
        // forge-lint: disable-next-line(incorrect-shift)
        uint256 mask = (1 << s) - 1;
        uint256 bestPlus1; // best score + 1, so the first legal direction always wins the comparison
        for (uint256 d; d < 4; ++d) {
            if ((legal >> d) & 1 != 0) {
                uint256 sc = ((v >> (s * d)) & mask) + 1;
                if (sc > bestPlus1) {
                    bestPlus1 = sc;
                    best = d;
                }
            }
        }
    }

    // ------------------------------------------------------------------ internals: encodings
    function _encodeX(uint256 board) internal pure returns (bytes memory x) {
        uint256 v;
        unchecked {
            for (uint256 i; i < CELLS; ++i) {
                uint256 e = (board >> (4 * i)) & 15;
                if (e > LEVELS - 1) e = LEVELS - 1;
                // forge-lint: disable-next-line(incorrect-shift)
                v |= 1 << (LEVELS * i + e);
            }
        }
        x = new bytes(X_BYTES);
        assembly {
            let p := add(x, 32)
            for { let i := 0 } lt(i, 24) { i := add(i, 1) } { mstore8(add(p, i), and(shr(shl(3, i), v), 0xff)) }
        }
    }

    function _decodeX(bytes calldata x) internal pure returns (uint256 board) {
        if (x.length != X_BYTES) revert BadInput();
        uint256 v;
        for (uint256 k = X_BYTES; k > 0; --k) {
            v = (v << 8) | uint8(x[k - 1]);
        }
        for (uint256 i; i < CELLS; ++i) {
            uint256 cell = (v >> (LEVELS * i)) & 0xfff;
            if (cell == 0 || cell & (cell - 1) != 0) revert BadInput(); // exactly one level bit per cell
            uint256 e;
            while (cell > 1) {
                cell >>= 1;
                ++e;
            }
            board |= e << (4 * i);
        }
    }

    // ------------------------------------------------------------------ internals: rules
    uint256 internal constant LOW = 0x1111111111111111; // bit 0 of every nibble
    uint256 internal constant PAIR_H = 0x0111011101110111; // cells k with k + 1 in the same row (c < 3)
    uint256 internal constant PAIR_V = 0x0000111111111111; // cells k with k + 4 on the board (r < 3)

    function _initial(bytes32 seed) internal pure returns (uint256) {
        return _spawn(_spawn(0, seed, 0), seed, 1);
    }

    /// Bit 0 of nibble k set iff cell k is non-empty.
    function _nz(uint256 b) internal pure returns (uint256) {
        return (b | (b >> 1) | (b >> 2) | (b >> 3)) & LOW;
    }

    function _spawn(uint256 board, bytes32 seed, uint256 t) internal pure returns (uint256) {
        uint256 empty = ~_nz(board) & LOW;
        if (empty == 0) return board; // never after a legal move
        uint256 count;
        unchecked {
            for (uint256 m = empty; m != 0; m &= m - 1) ++count;
        }
        uint256 r = uint256(keccak256(abi.encode(seed, t)));
        uint256 k = r % count;
        uint256 e = (r >> 128) % 10 == 0 ? 2 : 1;
        unchecked {
            for (uint256 i; i < CELLS; ++i) {
                if ((empty >> (4 * i)) & 1 != 0) {
                    if (k == 0) return board | (e << (4 * i));
                    --k;
                }
            }
        }
        return board; // unreachable
    }

    /// Legal-direction mask, bit d = direction d changes the board. Left: some row has an empty cell followed by a
    /// tile, or two equal tiles side by side; Right: a tile followed by an empty cell, or an equal pair; Up / Down the
    /// same on columns. Equal to "the move changes the board" (forge fuzz test, Python cross-check).
    function _legal(uint256 b) internal pure returns (uint256 legal) {
        uint256 nz = _nz(b);
        uint256 ez = ~nz & LOW;
        uint256 eqH = (_nz(b ^ (b >> 4)) ^ LOW) & nz & PAIR_H; // equal non-empty neighbours k, k + 1
        uint256 eqV = (_nz(b ^ (b >> 16)) ^ LOW) & nz & PAIR_V; // equal non-empty neighbours k, k + 4
        if ((ez & (nz >> 16) & PAIR_V) | eqV != 0) legal |= 1; // Up
        if ((nz & ((ez >> 4) & LOW) & PAIR_H) | eqH != 0) legal |= 2; // Right
        if ((nz & ((ez >> 16) & LOW) & PAIR_V) | eqV != 0) legal |= 4; // Down
        if ((ez & (nz >> 4) & PAIR_H) | eqH != 0) legal |= 8; // Left
    }

    /// Board after moving in direction d (no spawn) and the merge score.
    function _move(uint256 board, uint256 d) internal pure returns (uint256 next, uint256 gained) {
        if (d == 3) return _slideRows(board, false); // Left: rows toward c = 0
        if (d == 1) return _slideRows(board, true); // Right
        (next, gained) = _slideRows(_transpose(board), d == 2); // Up: columns toward r = 0; Down: toward r = 3
        next = _transpose(next);
    }

    /// Slide every 16-bit row toward nibble 0 (reverse = toward nibble 3).
    function _slideRows(uint256 b, bool reverse) internal pure returns (uint256 out, uint256 score) {
        unchecked {
            for (uint256 r; r < 4; ++r) {
                uint256 row = (b >> (16 * r)) & 0xffff;
                if (row == 0) continue;
                if (reverse) row = _reverseRow(row);
                (uint256 res, uint256 s) = _slideRow(row);
                if (reverse) res = _reverseRow(res);
                out |= res << (16 * r);
                score += s;
            }
        }
    }

    /// One line of 4 nibbles toward nibble 0: compress, merge equal neighbours once from the edge, pad with empties.
    function _slideRow(uint256 row) internal pure returns (uint256 res, uint256 score) {
        unchecked {
            uint256 tiles; // non-empty exponents packed from nibble 0
            uint256 n;
            for (uint256 k; k < 4; ++k) {
                uint256 v = (row >> (4 * k)) & 15;
                if (v != 0) {
                    tiles |= v << (4 * n);
                    ++n;
                }
            }
            uint256 i;
            uint256 p;
            while (i < n) {
                uint256 a = (tiles >> (4 * i)) & 15;
                if (i + 1 < n && (tiles >> (4 * (i + 1))) & 15 == a) {
                    res |= (a + 1) << (4 * p); // a <= 14 on reachable boards (e <= 9 within 1000 moves)
                    // forge-lint: disable-next-line(incorrect-shift)
                    score += 1 << (a + 1);
                    i += 2;
                } else {
                    res |= a << (4 * p);
                    ++i;
                }
                ++p;
            }
        }
    }

    function _reverseRow(uint256 r) internal pure returns (uint256) {
        return ((r >> 12) & 0xf) | ((r >> 4) & 0xf0) | ((r << 4) & 0xf00) | ((r << 12) & 0xf000);
    }

    /// 4x4 nibble transpose: cell (r, c) <-> (c, r).
    function _transpose(uint256 x) internal pure returns (uint256) {
        uint256 a = (x & 0xF0F00F0FF0F00F0F) | ((x & 0x0000F0F00000F0F0) << 12) | ((x & 0x0F0F00000F0F0000) >> 12);
        return (a & 0xFF00FF0000FF00FF) | ((a & 0x00FF00FF00000000) >> 24) | ((a & 0x00000000FF00FF00) << 24);
    }

    function _maxTile(uint256 board) internal pure returns (uint256) {
        uint256 m;
        for (uint256 i; i < CELLS; ++i) {
            uint256 e = (board >> (4 * i)) & 15;
            if (e > m) m = e;
        }
        // forge-lint: disable-next-line(incorrect-shift)
        return m == 0 ? 0 : 1 << m;
    }
}
