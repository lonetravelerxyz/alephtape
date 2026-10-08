// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {AlephRegistry} from "../src/AlephRegistry.sol";
import {AiJudge} from "../src/AiJudge.sol";
import {BnnGroth16Verifier} from "../src/verifiers/BnnGroth16Verifier.sol";
import {MockFactory, MockProcessor} from "./mocks/MockTapeOut.sol";

/// Spec R1 R2 E1 E2 E3 E4 J1. Uses a real BNN Groth16 proof fixture (8 words + 16 zero words).
contract AlephRegistryTest is Test {
    using stdJson for string;

    AlephRegistry reg;
    MockFactory factory;
    MockProcessor aleph0;
    MockProcessor other;
    BnnGroth16Verifier verifier;
    string fx;

    uint256 constant TOP = 6;
    bytes constant TOP_NETLIST = hex"02abababababababababababababababababababababab";

    function setUp() public {
        factory = new MockFactory();
        aleph0 = new MockProcessor(address(factory));
        other = new MockProcessor(address(factory));
        factory.setCPU(address(aleph0), true);
        factory.setCPU(address(other), true);
        verifier = new BnnGroth16Verifier();
        reg = new AlephRegistry(address(factory));
        reg.allowProcessor(address(aleph0));
        aleph0.put(TOP, TOP_NETLIST, 64, 70);
        aleph0.put(1, hex"00000002000003", 64, 1);
        other.put(TOP, TOP_NETLIST, 64, 70);
        fx = vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/bnn_proofs.json"));
    }

    function _subs() internal view returns (AlephRegistry.CircuitRef[] memory s) {
        s = new AlephRegistry.CircuitRef[](1);
        s[0] = AlephRegistry.CircuitRef(address(aleph0), 1);
    }

    function _case(uint256 i) internal view returns (bytes memory x, bytes memory y, uint256[24] memory proof) {
        string memory p = string.concat(".cases[", vm.toString(i), "]");
        x = fx.readBytes(string.concat(p, ".xHex"));
        y = fx.readBytes(string.concat(p, ".yHex"));
        bytes32[] memory w = fx.readBytes32Array(string.concat(p, ".proof"));
        for (uint256 k; k < 24; ++k) proof[k] = uint256(w[k]);
    }

    function _register() internal returns (bytes32) {
        return reg.register(address(aleph0), TOP, _subs(), address(verifier));
    }

    // R1: register a circuit on ℵ₀ (with sub-circuits) -> stores shape, flatHash, verifier
    function test_R1_register() public {
        bytes32 key = _register();
        AlephRegistry.Circuit memory c = reg.circuit(key);
        assertEq(c.processor, address(aleph0));
        assertEq(c.circuitId, TOP);
        assertEq(c.nIn, 64);
        assertEq(c.nOut, 70);
        assertEq(c.nPub, 2);
        assertEq(c.verifier, address(verifier));
        bytes32 expected = keccak256(
            abi.encode(keccak256(TOP_NETLIST), address(aleph0), uint256(1), keccak256(hex"00000002000003"))
        );
        assertEq(c.flatHash, expected);
    }

    // R2: processor not on the allow-list (or not a TapeOut CPU) -> revert
    function test_R2_rejectsForeignProcessor() public {
        vm.expectRevert(AlephRegistry.ProcessorNotAllowed.selector);
        reg.register(address(other), TOP, _subs(), address(verifier));
        reg.allowProcessor(address(other));
        factory.setCPU(address(other), false);
        vm.expectRevert(AlephRegistry.ProcessorNotAllowed.selector);
        reg.register(address(other), TOP, _subs(), address(verifier));
    }

    // E1: valid proof -> true, cached, event
    function test_E1_validProofCaches() public {
        bytes32 key = _register();
        (bytes memory x, bytes memory y, uint256[24] memory proof) = _case(0);
        vm.expectEmit(true, true, false, true);
        emit AlephRegistry.Proven(key, keccak256(x), x, y);
        assertTrue(reg.verifyEval(key, x, y, proof));
        (bool proven, bytes memory got) = reg.getResult(key, x);
        assertTrue(proven);
        assertEq(got, y);
    }

    // E2: wrong output or tampered proof -> revert, nothing cached
    function test_E2_rejectsWrongOutputAndTamperedProof() public {
        bytes32 key = _register();
        (bytes memory x, bytes memory y, uint256[24] memory proof) = _case(0);
        bytes memory yBad = bytes.concat(y);
        yBad[0] = yBad[0] ^ 0x01;
        vm.expectRevert(AlephRegistry.InvalidProof.selector);
        reg.verifyEval(key, x, yBad, proof);
        uint256[24] memory p2 = proof;
        p2[3] = p2[3] ^ 1;
        vm.expectRevert(AlephRegistry.InvalidProof.selector);
        reg.verifyEval(key, x, y, p2);
        (bool proven,) = reg.getResult(key, x);
        assertFalse(proven);
    }

    // E2d: a valid Groth16 proof with anything in the 16 padding words is rejected (no malleable padding)
    function test_E2d_rejectsNonZeroPadding() public {
        bytes32 key = _register();
        (bytes memory x, bytes memory y, uint256[24] memory proof) = _case(0);
        for (uint256 k = 8; k < 24; k += 15) {
            uint256[24] memory p;
            for (uint256 i; i < 24; ++i) p[i] = proof[i]; // a copy: memory arrays assign by reference
            p[k] = 1;
            vm.expectRevert(AlephRegistry.InvalidProof.selector);
            reg.verifyEval(key, x, y, p);
            uint256[2] memory pub = [uint256(1744058969298844696), uint256(640486428966766040290)];
            vm.expectRevert(BnnGroth16Verifier.NonZeroPadding.selector);
            verifier.verifyProof(p, pub);
        }
        (bool proven,) = reg.getResult(key, x);
        assertFalse(proven);
        assertTrue(reg.verifyEval(key, x, y, proof)); // the untouched proof still verifies
    }

    // E2b: malformed lengths / non-canonical padding bits -> revert
    function test_E2b_rejectsBadEncoding() public {
        bytes32 key = _register();
        (bytes memory x, bytes memory y, uint256[24] memory proof) = _case(0);
        vm.expectRevert(AlephRegistry.BadLength.selector);
        reg.verifyEval(key, bytes.concat(x, hex"00"), y, proof);
        bytes memory yPad = bytes.concat(y);
        yPad[8] = yPad[8] | 0x80; // bit 71 > nOut=70
        vm.expectRevert(AlephRegistry.NonCanonical.selector);
        reg.verifyEval(key, x, yPad, proof);
    }

    // E2c: too little gas must not turn a valid proof into InvalidProof
    function test_E2c_starvedCallRevertsInsufficientGas() public {
        bytes32 key = _register();
        (bytes memory x, bytes memory y, uint256[24] memory proof) = _case(0);
        vm.expectRevert(AlephRegistry.InsufficientGas.selector);
        reg.verifyEval{gas: 450_000}(key, x, y, proof);
        (bool proven,) = reg.getResult(key, x);
        assertFalse(proven);
    }

    // E3: cached result is readable by anyone; unknown input is not proven
    function test_E3_getResult() public {
        bytes32 key = _register();
        (bytes memory x0, bytes memory y0, uint256[24] memory p0) = _case(0);
        (bytes memory x1,,) = _case(1);
        reg.verifyEval(key, x0, y0, p0);
        (bool ok0, bytes memory g0) = reg.getResult(key, x0);
        (bool ok1,) = reg.getResult(key, x1);
        assertTrue(ok0);
        assertEq(g0, y0);
        assertFalse(ok1);
    }

    // E4: on-chain verification gas stays ~constant for the 86,581-constraint BNN (Groth16: 2 public inputs)
    function test_E4_verifyGas() public {
        bytes32 key = _register();
        (bytes memory x, bytes memory y, uint256[24] memory proof) = _case(1);
        uint256 g = gasleft();
        reg.verifyEval(key, x, y, proof);
        uint256 used = g - gasleft();
        emit log_named_uint("verifyEval gas (BNN, incl. cache write)", used);
        assertLt(used, 300_000); // PLONK was 327,612
        uint256[] memory pv = fx.readUintArray(".cases[1].pub");
        uint256[2] memory pub = [pv[0], pv[1]];
        g = gasleft();
        assertTrue(verifier.verifyProof(proof, pub));
        used = g - gasleft();
        emit log_named_uint("BnnGroth16Verifier.verifyProof gas (24-word wrapper + self-call)", used);
        assertLt(used, 250_000);
    }

    // J1: AiJudge reads the proven BNN result and scores the drawn digit
    function test_J1_aiJudge() public {
        bytes32 key = _register();
        AiJudge judge = new AiJudge(address(reg), key);
        (bytes memory x0, bytes memory y0, uint256[24] memory p0) = _case(0);
        vm.expectRevert(AiJudge.NotProven.selector);
        judge.judge(x0);
        reg.verifyEval(key, x0, y0, p0);
        assertEq(judge.target(), 0);
        uint8 digit = judge.judge(x0); // case 0 is the playground's sample digit 0
        assertEq(digit, 0);
        assertEq(judge.points(address(this)), 1);
        assertEq(judge.target(), 1);
    }

    function test_adminCannotAffectRegistered() public {
        bytes32 key = _register();
        vm.prank(address(0xBEEF));
        vm.expectRevert(AlephRegistry.NotOwner.selector);
        reg.allowProcessor(address(other));
        (bytes memory x, bytes memory y, uint256[24] memory proof) = _case(0);
        reg.setRegistrationsPaused(true);
        assertTrue(reg.verifyEval(key, x, y, proof)); // eval still works while new registrations are paused
    }
}
