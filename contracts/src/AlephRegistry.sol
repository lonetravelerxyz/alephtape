// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITapeOutFactory} from "./interfaces/ITapeOut.sol";

interface IProcessorView {
    function netlist(uint256 id) external view returns (bytes memory);
    function circuitInfo(uint256 id) external view returns (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount);
    function factory() external view returns (address);
}

/// @title AlephRegistry — ZK eval for TapeOut circuits of any size
/// @notice Registers a circuit taped out on an allowed processor (ℵ₀, ℵ₁, …) together with a PLONK
///         verifier generated deterministically from its flattened netlist. Anyone can then submit
///         "circuit(x) = y" with a proof; on success the result is cached for every contract to read.
/// @dev    Public inputs = x then y, bit-packed little-endian into 248-bit (31-byte) chunks — must match zk/compile.py.
contract AlephRegistry {
    error NotOwner();
    error ProcessorNotAllowed();
    error AlreadyAllowed();
    error RegistrationsPaused();
    error AlreadyRegistered();
    error UnknownCircuit();
    error NoVerifierCode();
    error BadLength();
    error NonCanonical();
    error InvalidProof();
    error InsufficientGas();

    struct CircuitRef {
        address processor;
        uint256 circuitId;
    }

    struct Circuit {
        address processor;
        uint256 circuitId;
        bytes32 flatHash; // keccak(top netlist hash, then (processor, id, netlist hash) per sub-circuit, in DFS order)
        uint32 nIn;
        uint32 nOut;
        uint8 nPub;
        bytes4 verifySelector;
        address verifier;
        address registrant;
    }

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ProcessorAllowed(address indexed processor);
    event RegistrationsPausedSet(bool paused);
    event Registered(
        bytes32 indexed key, address indexed processor, uint256 indexed circuitId, address verifier, bytes32 flatHash, address registrant
    );
    event Proven(bytes32 indexed key, bytes32 indexed xHash, bytes x, bytes y);

    uint256 internal constant CHUNK_BYTES = 31; // 248 bits per public field element
    /// snarkjs verifiers return false (not revert) when starved, so a starved valid proof would look invalid.
    /// Measured on X Layer mainnet (2026-10-03): BNN verifyProof needs ~298,900 gas incl. tx base cost.
    uint256 internal constant VERIFY_GAS = 500_000;
    uint256 internal constant GAS_MARGIN = 20_000; // >= VERIFY_GAS/63 so the call really receives VERIFY_GAS (EIP-150)

    ITapeOutFactory public immutable factory;
    address public owner;
    address public pendingOwner;
    bool public registrationsPaused;

    mapping(address => bool) public allowed;
    address[] public processors; // append-only allow-list history

    mapping(bytes32 => Circuit) internal circuits;
    mapping(bytes32 => mapping(bytes32 => bytes)) internal results;
    mapping(bytes32 => mapping(bytes32 => bool)) internal provenFlag;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address factory_) {
        factory = ITapeOutFactory(factory_);
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // ------------------------------------------------------------------ admin (cannot touch registered circuits)
    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    /// @notice Append a processor generation (ℵ₀ → ℵ₁ …). There is no removal.
    function allowProcessor(address processor) external onlyOwner {
        if (allowed[processor]) revert AlreadyAllowed();
        allowed[processor] = true;
        processors.push(processor);
        emit ProcessorAllowed(processor);
    }

    function setRegistrationsPaused(bool paused) external onlyOwner {
        registrationsPaused = paused;
        emit RegistrationsPausedSet(paused);
    }

    // ------------------------------------------------------------------ register
    function register(address processor, uint256 circuitId, CircuitRef[] calldata subs, address verifier)
        external
        returns (bytes32 key)
    {
        if (registrationsPaused) revert RegistrationsPaused();
        _checkProcessor(processor);
        if (verifier.code.length == 0) revert NoVerifierCode();
        key = keccak256(abi.encode(processor, circuitId, verifier));
        if (circuits[key].processor != address(0)) revert AlreadyRegistered();

        // The registrant supplies the sub-circuit list (DFS order of the REFs in the top netlist); the contract
        // hashes the netlists it names but does not parse REFs. Anyone can recompute flatHash and the verifier
        // off-chain from the on-chain netlists (zk/compile.py) — the UI's "regenerate & check" does exactly that.
        bytes memory acc = abi.encode(keccak256(IProcessorView(processor).netlist(circuitId)));
        for (uint256 i; i < subs.length; ++i) {
            _checkProcessor(subs[i].processor);
            acc = bytes.concat(
                acc,
                abi.encode(
                    subs[i].processor,
                    subs[i].circuitId,
                    keccak256(IProcessorView(subs[i].processor).netlist(subs[i].circuitId))
                )
            );
        }
        (uint32 nIn, uint32 nOut,,) = IProcessorView(processor).circuitInfo(circuitId);
        uint256 nPub = _chunks(nIn) + _chunks(nOut);
        bytes32 flatHash = keccak256(acc);
        circuits[key] = Circuit({
            processor: processor,
            circuitId: circuitId,
            flatHash: flatHash,
            nIn: nIn,
            nOut: nOut,
            nPub: uint8(nPub),
            verifySelector: bytes4(keccak256(abi.encodePacked("verifyProof(uint256[24],uint256[", _toString(nPub), "])"))),
            verifier: verifier,
            registrant: msg.sender
        });
        emit Registered(key, processor, circuitId, verifier, flatHash, msg.sender);
    }

    // ------------------------------------------------------------------ ZK eval
    /// @notice Verify "circuit(x) = y" and cache it. x, y are bit-packed little-endian, ceil(n/8) bytes.
    function verifyEval(bytes32 key, bytes calldata x, bytes calldata y, uint256[24] calldata proof)
        external
        returns (bool)
    {
        Circuit storage c = circuits[key];
        if (c.verifier == address(0)) revert UnknownCircuit();
        _checkEncoding(x, c.nIn);
        _checkEncoding(y, c.nOut);

        bytes memory data = abi.encodePacked(c.verifySelector, proof, _words(x), _words(y));
        if (gasleft() < VERIFY_GAS + GAS_MARGIN) revert InsufficientGas();
        (bool ok, bytes memory ret) = c.verifier.staticcall{gas: VERIFY_GAS}(data);
        if (!ok || ret.length != 32 || !abi.decode(ret, (bool))) revert InvalidProof();

        bytes32 h = keccak256(x);
        if (!provenFlag[key][h]) {
            provenFlag[key][h] = true;
            results[key][h] = y;
        }
        emit Proven(key, h, x, y);
        return true;
    }

    function getResult(bytes32 key, bytes calldata x) external view returns (bool proven, bytes memory y) {
        bytes32 h = keccak256(x);
        return (provenFlag[key][h], results[key][h]);
    }

    function circuit(bytes32 key) external view returns (Circuit memory) {
        return circuits[key];
    }

    function processorCount() external view returns (uint256) {
        return processors.length;
    }

    // ------------------------------------------------------------------ internals
    function _checkProcessor(address p) internal view {
        if (!allowed[p] || !factory.isCPU(p) || IProcessorView(p).factory() != address(factory)) {
            revert ProcessorNotAllowed();
        }
    }

    function _chunks(uint256 nBits) internal pure returns (uint256) {
        return (nBits + CHUNK_BYTES * 8 - 1) / (CHUNK_BYTES * 8);
    }

    function _checkEncoding(bytes calldata b, uint256 nBits) internal pure {
        if (b.length != (nBits + 7) / 8) revert BadLength();
        uint256 rem = nBits % 8;
        if (rem != 0 && (uint8(b[b.length - 1]) >> rem) != 0) revert NonCanonical();
    }

    /// little-endian 31-byte chunks -> field elements
    function _words(bytes calldata b) internal pure returns (uint256[] memory w) {
        uint256 n = (b.length + CHUNK_BYTES - 1) / CHUNK_BYTES;
        w = new uint256[](n);
        for (uint256 c; c < n; ++c) {
            uint256 v;
            uint256 end = (c + 1) * CHUNK_BYTES;
            if (end > b.length) end = b.length;
            for (uint256 j = end; j > c * CHUNK_BYTES; --j) {
                v = (v << 8) | uint8(b[j - 1]);
            }
            w[c] = v;
        }
    }

    function _toString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        bytes memory s;
        while (v != 0) {
            s = abi.encodePacked(bytes1(uint8(48 + (v % 10))), s);
            v /= 10;
        }
        return string(s);
    }
}
