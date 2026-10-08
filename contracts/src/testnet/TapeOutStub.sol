// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// TESTNET ONLY. TapeOut is not deployed on X Layer testnet (chain 1952), so the testnet end-to-end run
/// uses this stand-in for the two read paths AlephRegistry needs: factory.isCPU / processor.factory()
/// and processor.netlist() / circuitInfo(). It stores the same netlists the real tapeout would.
/// Real TapeOut behavior (tapeout, burns, REF eval) was checked on a fork of X Layer mainnet.
contract TapeOutStubFactory {
    address public immutable owner;
    mapping(address => bool) public isCPU;

    constructor() {
        owner = msg.sender;
    }

    function setCPU(address cpu, bool ok) external {
        require(msg.sender == owner, "owner");
        isCPU[cpu] = ok;
    }
}

contract TapeOutStubProcessor {
    struct C {
        bytes netlist;
        uint32 nIn;
        uint32 nOut;
        bool exists;
    }

    address public immutable owner;
    address public immutable factory;
    mapping(uint256 => C) internal circuits;

    event Put(uint256 indexed id, uint32 nIn, uint32 nOut, uint256 bytesLen);

    constructor(address factory_) {
        owner = msg.sender;
        factory = factory_;
    }

    function put(uint256 id, bytes calldata nl, uint32 nIn, uint32 nOut) external {
        require(msg.sender == owner, "owner");
        require(!circuits[id].exists, "exists");
        circuits[id] = C(nl, nIn, nOut, true);
        emit Put(id, nIn, nOut, nl.length);
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
