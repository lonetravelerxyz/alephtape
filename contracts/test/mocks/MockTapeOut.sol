// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Minimal stand-ins for the TapeOut factory and a processor (netlist storage + circuitInfo).
contract MockFactory {
    mapping(address => bool) public isCPU;

    function setCPU(address cpu, bool ok) external {
        isCPU[cpu] = ok;
    }
}

contract MockProcessor {
    struct C {
        bytes netlist;
        uint32 nIn;
        uint32 nOut;
        bool exists;
    }

    address public factory;
    mapping(uint256 => C) internal circuits;

    constructor(address factory_) {
        factory = factory_;
    }

    function put(uint256 id, bytes calldata netlist_, uint32 nIn, uint32 nOut) external {
        circuits[id] = C(netlist_, nIn, nOut, true);
    }

    function netlist(uint256 id) external view returns (bytes memory) {
        require(circuits[id].exists, "no circuit");
        return circuits[id].netlist;
    }

    function circuitInfo(uint256 id) external view returns (uint32, uint32, uint32, uint32) {
        require(circuits[id].exists, "no circuit");
        return (circuits[id].nIn, circuits[id].nOut, 0, 0);
    }
}
