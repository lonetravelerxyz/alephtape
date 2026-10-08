// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Stand-in for a Groth16 verifier behind the REAL AlephRegistry (arena tests): answers any
/// verifyProof(uint256[24] p, uint256[nPub] pub) with true iff p[0] == keccak256(pub words), i.e. a "proof" binds
/// exactly one (x, y). A tampered y (or proof word) fails like a real verifier would. Burns ~`burn` gas first so
/// gas measurements match a real verifier (~210k).
contract TruthVerifier {
    uint256 public immutable burn;

    constructor(uint256 burn_) {
        burn = burn_;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        uint256 start = gasleft();
        while (start - gasleft() < burn) {}
        uint256 p0 = uint256(bytes32(data[4:36]));
        bytes32 h = keccak256(data[4 + 24 * 32:]);
        return abi.encode(p0 == uint256(h));
    }
}
