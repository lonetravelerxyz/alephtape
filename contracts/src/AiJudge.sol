// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AlephRegistry} from "./AlephRegistry.sol";

/// @title AiJudge — demo consumer of a ZK-proven BNN result
/// @notice "Draw the target digit": the BNN is ~161k gates, far beyond a block if evaluated directly.
///         Players first get "BNN(x) = scores" proven in AlephRegistry, then call judge(x).
contract AiJudge {
    error NotProven();

    uint256 internal constant CLASSES = 10;
    uint256 internal constant SCORE_BITS = 7;

    AlephRegistry public immutable registry;
    bytes32 public immutable bnnKey;
    uint8 public target;
    mapping(address => uint256) public points;

    event Judged(address indexed player, bytes32 indexed xHash, uint8 digit, uint8 target, bool hit);

    constructor(address registry_, bytes32 bnnKey_) {
        registry = AlephRegistry(registry_);
        bnnKey = bnnKey_;
    }

    function judge(bytes calldata x) external returns (uint8 digit) {
        (bool proven, bytes memory y) = registry.getResult(bnnKey, x);
        if (!proven) revert NotProven();
        digit = argmax(scores(y));
        uint8 t = target;
        bool hit = digit == t;
        if (hit) {
            points[msg.sender] += 1;
            target = uint8((t + 1) % CLASSES);
        }
        emit Judged(msg.sender, keccak256(x), digit, t, hit);
    }

    /// 70 output bits -> 10 popcount scores (7 bits each, little-endian; neuron_out bit order is s[0..6]).
    function scores(bytes memory y) public pure returns (uint8[10] memory s) {
        for (uint256 k; k < CLASSES; ++k) {
            uint256 v;
            for (uint256 b; b < SCORE_BITS; ++b) {
                uint256 i = k * SCORE_BITS + b;
                v |= ((uint256(uint8(y[i >> 3])) >> (i & 7)) & 1) << b;
            }
            s[k] = uint8(v);
        }
    }

    function argmax(uint8[10] memory s) public pure returns (uint8 best) {
        for (uint8 k = 1; k < CLASSES; ++k) {
            if (s[k] > s[best]) best = k;
        }
    }
}
