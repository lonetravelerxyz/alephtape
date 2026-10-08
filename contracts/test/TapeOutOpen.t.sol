// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TapeOutOpenProcessor, TapeOutOpenTransistors} from "../src/testnet/TapeOutOpen.sol";

contract TapeOutOpenTest is Test {
    TapeOutOpenProcessor p;
    TapeOutOpenTransistors t;
    address alice = address(0xA11CE);

    event TapedOut(uint256 indexed circuitId, address indexed author, uint32 gateCount, uint32 nState);

    function setUp() public {
        p = new TapeOutOpenProcessor(address(0xFAC), 13e12, 66e10, 66e11, 1_000_000);
        t = p.transistors();
        vm.deal(alice, 1 ether);
    }

    // in0 = signal 2; NAND(2,1), NAND(2,0), NAND(3,4)
    function _nl() internal pure returns (bytes memory) {
        return hex"00000002000001" hex"00000002000000" hex"00000003000004";
    }

    function test_mint_tapeout_burns_and_emits() public {
        vm.startPrank(alice);
        vm.expectRevert("mint fee");
        t.mint{value: 1}(0, 3);
        t.mint{value: 66e10 * 3 + 66e11}(0, 3);
        assertEq(t.balanceOf(alice, 0), 3);
        vm.expectRevert("tapeout fee");
        p.tapeout{value: 1}(_nl(), 1, 1);
        vm.expectEmit(true, true, false, true);
        emit TapedOut(1, alice, 3, 0);
        uint256 id = p.tapeout{value: 13e12}(_nl(), 1, 1);
        vm.stopPrank();
        assertEq(id, 1);
        assertEq(p.nextId(), 2);
        assertEq(t.balanceOf(alice, 0), 0);
        assertEq(p.ownerOf(1), alice);
        assertEq(p.netlist(1), _nl());
        (uint32 nIn, uint32 nOut, uint32 nState, uint32 gates) = p.circuitInfo(1);
        assertEq(abi.encode(nIn, nOut, nState, gates), abi.encode(uint32(1), uint32(1), uint32(0), uint32(3)));
    }

    function test_needs_transistors_and_valid_netlist() public {
        vm.startPrank(alice);
        vm.expectRevert("insufficient transistors");
        p.tapeout{value: 13e12}(_nl(), 1, 1);
        t.mint{value: 66e10 * 3 + 66e11}(0, 3);
        vm.expectRevert("bad signal");
        p.tapeout{value: 13e12}(hex"00000005000000", 1, 1); // forward reference
        vm.expectRevert("bad opcode");
        p.tapeout{value: 13e12}(hex"07", 1, 1);
        vm.stopPrank();
    }

    function test_ref_burns_nothing() public {
        vm.startPrank(alice);
        t.mint{value: 66e10 * 3 + 66e11}(0, 3);
        p.tapeout{value: 13e12}(_nl(), 1, 1);
        // REF to circuit 1 on this processor with input signal 2, one output
        bytes memory ref = abi.encodePacked(hex"02", address(p), uint64(1), uint8(1), uint8(1), hex"000002");
        uint256 id = p.tapeout{value: 13e12}(ref, 1, 1);
        vm.stopPrank();
        (,,, uint32 gates) = p.circuitInfo(id);
        assertEq(gates, 0);
    }
}
