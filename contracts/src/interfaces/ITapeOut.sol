// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// TapeOut processor (= circuits contract) on X Layer. ABI verified on-chain 2026-10-03.
/// Inputs/outputs are little-endian bit-packed, ceil(n/8) bytes.
interface ITapeOutProcessor {
    function eval(uint256 id, bytes calldata inputs) external view returns (bytes memory);
    function step(uint256 id, bytes calldata state, bytes calldata inputs)
        external
        view
        returns (bytes memory newState, bytes memory outputs);
    function circuitInfo(uint256 id) external view returns (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount);
    function netlist(uint256 id) external view returns (bytes memory);
    function ownerOf(uint256 id) external view returns (address);
    function factory() external view returns (address);
}

/// TapeOut factory, X Layer: 0x1f09daefa827f02cbb40967cc91b259763760761 (UUPS proxy, owner 3/5 Safe).
interface ITapeOutFactory {
    function isCPU(address cpu) external view returns (bool);
}
