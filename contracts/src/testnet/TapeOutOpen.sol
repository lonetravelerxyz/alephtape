// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// TESTNET ONLY. TapeOut is not on X Layer testnet and the stub processor (TapeOutStub.sol) only takes
/// netlists from its owner, so outsiders could not tape out a 刻印 / Stamp (the zkgen payment circuit) there. This
/// stand-in copies the public surface of a real TapeOut processor and its transistor contract, so the browser and the
/// zkgen service run the same code path as on ℵ₀ mainnet:
///   transistors().mint(0, n) payable (mintPrice * n + protocolFee per tx)  ->  tapeout(nl, nIn, nOut) payable
///   (value == TAPEOUT_FEE exactly; burns one NAND transistor per NAND element, one LATCH per LATCH, REF burns none)
///   -> TapedOut(circuitId, author, gateCount, nState); netlist / circuitInfo / ownerOf / nextId / factory.
/// Not copied: REF targets are not checked against the factory, and circuits are not transferable.
contract TapeOutOpenTransistors {
    address public immutable processor;
    uint256 public immutable mintPrice;
    uint256 public immutable protocolFee;
    uint256 public immutable supplyCap;
    address public immutable owner;
    uint256 public minted;
    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);

    constructor(address owner_, uint256 mintPrice_, uint256 protocolFee_, uint256 supplyCap_) {
        processor = msg.sender;
        owner = owner_;
        mintPrice = mintPrice_;
        protocolFee = protocolFee_;
        supplyCap = supplyCap_;
    }

    function mint(uint256 id, uint256 amount) external payable {
        require(id <= 1, "bad id");
        require(msg.value == mintPrice * amount + protocolFee, "mint fee");
        require(minted + amount <= supplyCap, "supply cap");
        minted += amount;
        balanceOf[msg.sender][id] += amount;
        emit TransferSingle(msg.sender, address(0), msg.sender, id, amount);
    }

    function burnFrom(address from, uint256 id, uint256 amount) external {
        require(msg.sender == processor, "processor");
        require(balanceOf[from][id] >= amount, "insufficient transistors");
        balanceOf[from][id] -= amount;
        emit TransferSingle(msg.sender, from, address(0), id, amount);
    }

    function withdraw() external {
        require(msg.sender == owner, "owner");
        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }
}

contract TapeOutOpenProcessor {
    struct C {
        bytes netlist;
        uint32 nIn;
        uint32 nOut;
        uint32 nState;
        uint32 gateCount;
        address author;
    }

    address public immutable owner;
    address public immutable factory;
    uint256 public immutable TAPEOUT_FEE;
    TapeOutOpenTransistors public immutable transistors;
    uint256 public nextId = 1;
    mapping(uint256 => C) internal circuits;

    event TapedOut(uint256 indexed circuitId, address indexed author, uint32 gateCount, uint32 nState);

    constructor(address factory_, uint256 tapeoutFee, uint256 mintPrice, uint256 protocolFee, uint256 supplyCap) {
        owner = msg.sender;
        factory = factory_;
        TAPEOUT_FEE = tapeoutFee;
        transistors = new TapeOutOpenTransistors(msg.sender, mintPrice, protocolFee, supplyCap);
    }

    function tapeout(bytes calldata nl, uint32 nIn, uint32 nOut) external payable returns (uint256 id) {
        require(msg.value == TAPEOUT_FEE, "tapeout fee");
        require(nOut > 0, "no outputs");
        (uint32 nands, uint32 latches, uint256 signals) = _scan(nl, nIn);
        require(signals >= 2 + uint256(nIn) + nOut, "too few signals for outputs");
        if (nands > 0) transistors.burnFrom(msg.sender, 0, nands);
        if (latches > 0) transistors.burnFrom(msg.sender, 1, latches);
        id = nextId++;
        circuits[id] = C(nl, nIn, nOut, latches, nands, msg.sender);
        emit TapedOut(id, msg.sender, nands, latches);
    }

    function netlist(uint256 id) external view returns (bytes memory) {
        require(circuits[id].author != address(0), "no circuit");
        return circuits[id].netlist;
    }

    function circuitInfo(uint256 id) external view returns (uint32, uint32, uint32, uint32) {
        C storage c = circuits[id];
        require(c.author != address(0), "no circuit");
        return (c.nIn, c.nOut, c.nState, c.gateCount);
    }

    function ownerOf(uint256 id) external view returns (address) {
        require(circuits[id].author != address(0), "no circuit");
        return circuits[id].author;
    }

    function withdraw() external {
        require(msg.sender == owner, "owner");
        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }

    /// Element walk of the TapeOut netlist format: NAND 7 bytes (refs < own index), LATCH 4, REF 32 + 3 * nIn.
    function _scan(bytes calldata nl, uint32 nIn) internal pure returns (uint32 nands, uint32 latches, uint256 sig) {
        sig = 2 + uint256(nIn);
        uint256 p;
        while (p < nl.length) {
            uint8 op = uint8(nl[p]);
            if (op == 0) {
                require(p + 7 <= nl.length, "size overflow");
                require(_u24(nl, p + 1) < sig && _u24(nl, p + 4) < sig, "bad signal");
                nands++;
                sig++;
                p += 7;
            } else if (op == 1) {
                require(p + 4 <= nl.length, "size overflow");
                latches++;
                sig++;
                p += 4;
            } else if (op == 2) {
                require(p + 31 <= nl.length, "REF size");
                uint256 ni = uint8(nl[p + 29]);
                uint256 no = uint8(nl[p + 30]);
                require(p + 31 + 3 * ni <= nl.length, "REF size");
                sig += no;
                p += 31 + 3 * ni;
            } else {
                revert("bad opcode");
            }
        }
    }

    function _u24(bytes calldata b, uint256 i) internal pure returns (uint256) {
        return (uint256(uint8(b[i])) << 16) | (uint256(uint8(b[i + 1])) << 8) | uint256(uint8(b[i + 2]));
    }
}
