// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title GomokuRules — the 9×9 gomoku rule and selection code shared by AlephGomoku and AlephGomokuArena
/// @notice Pure bitboard functions. "own" is the side to move (AlephGomoku: the
///         AI; the arena: whichever AI is on move), "opp" the other side. Selection rule: 1) lowest empty cell where
///         own makes five; 2) else where opp would; 3) else where own makes an open four; 4) else where opp would;
///         5) else the empty cell with the highest circuit score, ties to the lowest index. Rules 1–4 need no scores.
/// @dev    Cell i = r*9 + c. x (162 bits, 21 bytes LE) = own stones in bits 0..80, opp stones in bits 81..161.
///         y (486 bits, 61 bytes LE) = 81 scores, cell k in bits [6k, 6k+6), LSB first. All functions are internal
///         (inlined into each contract); the code moved here verbatim from AlephGomoku.
library GomokuRules {
    error BadInput(); // x not 21 canonical bytes / inconsistent board, or y not 61 bytes (same selector as AlephGomoku's)

    uint256 internal constant CELLS = 81;
    uint256 internal constant X_BYTES = 21;
    uint256 internal constant Y_BYTES = 61;
    uint256 internal constant BOARD = 0x1ffffffffffffffffffff; // bits 0..80
    uint256 internal constant COL0 = 0x1008040201008040201; // c == 0
    uint256 internal constant COL8 = 0x100804020100804020100; // c == 8
    uint256 internal constant NOT_COL0 = BOARD & ~COL0;
    uint256 internal constant NOT_COL8 = BOARD & ~COL8;
    uint256 internal constant NO_RULE = type(uint256).max; // ruleMove: rules 1-4 do not fire

    /// x bytes -> (own, opp) bitboards; BadInput unless 21 bytes, canonical, disjoint and not full.
    function decodeX(bytes calldata x) internal pure returns (uint256 own, uint256 opp) {
        if (x.length != X_BYTES) revert BadInput();
        uint256 v;
        for (uint256 i = X_BYTES; i > 0; --i) {
            v = (v << 8) | uint8(x[i - 1]);
        }
        own = v & BOARD;
        opp = (v >> CELLS) & BOARD;
        if (v >> (2 * CELLS) != 0 || own & opp != 0 || (own | opp) == BOARD) revert BadInput();
    }

    function encodeX(uint256 own, uint256 opp) internal pure returns (bytes memory x) {
        uint256 v = own | (opp << CELLS);
        x = new bytes(X_BYTES);
        assembly {
            let p := add(x, 32)
            for { let i := 0 } lt(i, 21) { i := add(i, 1) } { mstore8(add(p, i), and(shr(shl(3, i), v), 0xff)) }
        }
    }

    /// Rules 1–4, which need no scores: 1) lowest empty cell where own makes five; 2) else lowest where opp would;
    /// 3) else lowest where own makes an open four; 4) else lowest where opp would. NO_RULE if none.
    function ruleMove(uint256 own, uint256 opp) internal pure returns (uint256) {
        uint256 empty = BOARD & ~(own | opp);
        uint256 w = winCells(own, empty);
        if (w != 0) return lowestBit(w);
        w = winCells(opp, empty);
        if (w != 0) return lowestBit(w);
        w = openFourCells(own, empty);
        if (w != 0) return lowestBit(w);
        w = openFourCells(opp, empty);
        if (w != 0) return lowestBit(w);
        return NO_RULE;
    }

    /// Rule 5: the empty cell with the highest score in y, ties to the lowest index. Assumes at least one empty
    /// cell (true at every move of an unfinished game before ply 81).
    function argmax(uint256 occupied, bytes memory y) internal pure returns (uint256) {
        uint256 empty = BOARD & ~occupied;
        if (y.length != Y_BYTES) revert BadInput();
        uint256 lo;
        uint256 hi;
        assembly {
            lo := mload(add(y, 32))
            hi := mload(add(y, 64)) // bytes 61..63 are past the end; they only reach bits >= 232 of hi, never read
        }
        lo = reverseBytes(lo); // bits 0..255 of y
        hi = reverseBytes(hi); // bits 256..511 of y
        uint256 best;
        uint256 bestPlus1; // best score + 1, so the first empty cell always wins the comparison
        unchecked {
            for (uint256 k; k < CELLS; ++k) {
                if (empty & 1 != 0) {
                    uint256 s = (lo & 63) + 1;
                    if (s > bestPlus1) {
                        bestPlus1 = s;
                        best = k;
                        if (s == 64) break; // 63 is the top score; later ties lose anyway
                    }
                }
                empty >>= 1;
                lo = (lo >> 6) | (hi << 250); // slide the 512-bit score stream by one cell
                hi >>= 6;
            }
        }
        return best;
    }

    // Line directions with step s: (X >> s) & mF = cells i with i+s in X on the same line, (X << s) & mB = cells
    // with i-s in X. Column masks stop row wrap on steps 1 (→), 10 (↘) and 8 (↙); step 9 (↓) only needs BOARD.

    /// Five (or more) in a row anywhere on P. Called right after each move; no earlier five can exist
    /// (the game would have ended), so any five found runs through the last move.
    function hasFive(uint256 P) internal pure returns (bool) {
        return _fiveDir(P, 1, NOT_COL8) || _fiveDir(P, 9, BOARD) || _fiveDir(P, 10, NOT_COL8)
            || _fiveDir(P, 8, NOT_COL0);
    }

    function _fiveDir(uint256 P, uint256 s, uint256 mF) private pure returns (bool) {
        uint256 a = P & ((P >> s) & mF); // i, i+s
        uint256 b = a & ((a >> (2 * s)) & mF); // i, i+s, i+2s, i+3s (link i+s -> i+2s not yet checked)
        return b & (b >> s) != 0; // b[i] & b[i+s] checks all four links i .. i+4s
    }

    /// Empty cells where one more stone of P completes five (or more) in some direction.
    function winCells(uint256 P, uint256 empty) internal pure returns (uint256) {
        return (
            _winDir(P, 1, NOT_COL8, NOT_COL0) | _winDir(P, 9, BOARD, BOARD) | _winDir(P, 10, NOT_COL8, NOT_COL0)
                | _winDir(P, 8, NOT_COL0, NOT_COL8)
        ) & empty;
    }

    function _winDir(uint256 P, uint256 s, uint256 mF, uint256 mB) private pure returns (uint256) {
        uint256 a1 = (P >> s) & mF; // stone at i+s
        uint256 a2 = a1 & (a1 >> s) & mF; // i+s, i+2s
        uint256 a3 = a1 & (a2 >> s) & mF;
        uint256 a4 = a1 & (a3 >> s) & mF;
        uint256 b1 = (P << s) & mB; // stone at i-s
        uint256 b2 = b1 & (b1 << s) & mB;
        uint256 b3 = b1 & (b2 << s) & mB;
        uint256 b4 = b1 & (b3 << s) & mB;
        return a4 | (a3 & b1) | (a2 & b2) | (a1 & b3) | b4;
    }

    /// Empty cells p where one more stone of P makes an open four: in some direction the run through p is exactly
    /// 4 long (f stones forward + b backward, f + b == 3) and the cells just past both ends are on the line and empty.
    function openFourCells(uint256 P, uint256 empty) internal pure returns (uint256) {
        return (
            _openFourDir(P, empty, 1, NOT_COL8, NOT_COL0) | _openFourDir(P, empty, 9, BOARD, BOARD)
                | _openFourDir(P, empty, 10, NOT_COL8, NOT_COL0) | _openFourDir(P, empty, 8, NOT_COL0, NOT_COL8)
        ) & empty;
    }

    function _openFourDir(uint256 P, uint256 E, uint256 s, uint256 mF, uint256 mB) private pure returns (uint256) {
        (uint256 f0, uint256 f1, uint256 f2, uint256 f3) = _runsFwd(P, E, s, mF);
        (uint256 b0, uint256 b1, uint256 b2, uint256 b3) = _runsBwd(P, E, s, mB);
        return (f3 & b0) | (f2 & b1) | (f1 & b2) | (f0 & b3);
    }

    /// r_k: cells i with stones at i+s..i+ks and an empty cell at i+(k+1)s, all on i's line.
    function _runsFwd(uint256 P, uint256 E, uint256 s, uint256 m)
        private
        pure
        returns (uint256 r0, uint256 r1, uint256 r2, uint256 r3)
    {
        uint256 a1 = (P >> s) & m;
        uint256 a2 = a1 & (a1 >> s) & m;
        uint256 a3 = a1 & (a2 >> s) & m;
        uint256 e = (E >> s) & m;
        r0 = e;
        e = (e >> s) & m;
        r1 = a1 & e;
        e = (e >> s) & m;
        r2 = a2 & e;
        e = (e >> s) & m;
        r3 = a3 & e;
    }

    /// Same as _runsFwd towards i-s, i-2s, ...
    function _runsBwd(uint256 P, uint256 E, uint256 s, uint256 m)
        private
        pure
        returns (uint256 r0, uint256 r1, uint256 r2, uint256 r3)
    {
        uint256 a1 = (P << s) & m;
        uint256 a2 = a1 & (a1 << s) & m;
        uint256 a3 = a1 & (a2 << s) & m;
        uint256 e = (E << s) & m;
        r0 = e;
        e = (e << s) & m;
        r1 = a1 & e;
        e = (e << s) & m;
        r2 = a2 & e;
        e = (e << s) & m;
        r3 = a3 & e;
    }

    function lowestBit(uint256 v) internal pure returns (uint256 r) {
        unchecked {
            v &= 0 - v;
        }
        if (v >> 64 != 0) {
            v >>= 64;
            r += 64;
        }
        if (v >> 32 != 0) {
            v >>= 32;
            r += 32;
        }
        if (v >> 16 != 0) {
            v >>= 16;
            r += 16;
        }
        if (v >> 8 != 0) {
            v >>= 8;
            r += 8;
        }
        if (v >> 4 != 0) {
            v >>= 4;
            r += 4;
        }
        if (v >> 2 != 0) {
            v >>= 2;
            r += 2;
        }
        if (v >> 1 != 0) r += 1;
    }

    function reverseBytes(uint256 v) internal pure returns (uint256) {
        v = ((v >> 8) & 0x00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff)
            | ((v & 0x00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff) << 8);
        v = ((v >> 16) & 0x0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff)
            | ((v & 0x0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff) << 16);
        v = ((v >> 32) & 0x00000000ffffffff00000000ffffffff00000000ffffffff00000000ffffffff)
            | ((v & 0x00000000ffffffff00000000ffffffff00000000ffffffff00000000ffffffff) << 32);
        v = ((v >> 64) & 0x0000000000000000ffffffffffffffff0000000000000000ffffffffffffffff)
            | ((v & 0x0000000000000000ffffffffffffffff0000000000000000ffffffffffffffff) << 64);
        return (v >> 128) | (v << 128);
    }
}
