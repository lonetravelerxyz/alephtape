// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Controllable stand-in for AlephRegistry's getResult / verifyEval (AlephGomoku tests G1–G6).
/// "truth" is what the circuit would output for x: verifyEval accepts exactly that y (soundness),
/// caches it like the real registry, and counts calls. Hooks: fail every verify, or return false.
contract MockAlephEval {
    error InvalidProof();

    mapping(bytes32 => bytes) internal truth;
    mapping(bytes32 => bool) internal hasTruth;
    mapping(bytes32 => bytes) internal cache;
    mapping(bytes32 => bool) internal cached;

    bool public failVerify;
    bool public returnFalse;
    uint256 public verifyCalls;
    bytes32 public lastKey;

    function setTruth(bytes calldata x, bytes calldata y) external {
        truth[keccak256(x)] = y;
        hasTruth[keccak256(x)] = true;
    }

    function setCached(bytes calldata x, bytes calldata y) external {
        cache[keccak256(x)] = y;
        cached[keccak256(x)] = true;
    }

    function setFailVerify(bool v) external {
        failVerify = v;
    }

    function setReturnFalse(bool v) external {
        returnFalse = v;
    }

    function getResult(bytes32, bytes calldata x) external view returns (bool, bytes memory) {
        return (cached[keccak256(x)], cache[keccak256(x)]);
    }

    function verifyEval(bytes32 key, bytes calldata x, bytes calldata y, uint256[24] calldata)
        external
        returns (bool)
    {
        verifyCalls++;
        lastKey = key;
        if (failVerify) revert InvalidProof();
        if (returnFalse) return false;
        bytes32 h = keccak256(x);
        if (!hasTruth[h] || keccak256(truth[h]) != keccak256(y)) revert InvalidProof();
        cache[h] = y;
        cached[h] = true;
        return true;
    }
}

/// Answers any verifyProof(...) call with `true` after burning ~`burn` gas: a stand-in for a real Groth16
/// verifier (~210k) behind the real AlephRegistry, for end-to-end gas measurement (G7).
contract GasBurnVerifier {
    uint256 public immutable burn;

    constructor(uint256 burn_) {
        burn = burn_;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        uint256 start = gasleft();
        while (start - gasleft() < burn) {}
        return abi.encode(true);
    }
}
