// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ProbeConstants} from "../../src/generated/ProbeConstants.sol";

/// @notice "A changed probe result fails the build": the generated constants must match
///         deployments/probes.json exactly. Run `just gen` after `just probe` to regenerate.
contract ProbeConstantsTest is Test {
    string internal json;

    function setUp() public {
        json = vm.readFile("deployments/probes.json");
    }

    function test_opcodesMatchProbeFile() public view {
        assertEq(vm.parseJsonUint(json, ".opcodes.APPROVE.op"), ProbeConstants.OP_APPROVE);
        assertEq(vm.parseJsonUint(json, ".opcodes.TXPARAM.op"), ProbeConstants.OP_TXPARAM);
        assertEq(vm.parseJsonUint(json, ".opcodes.FRAMEPARAM.op"), ProbeConstants.OP_FRAMEPARAM);
        assertEq(vm.parseJsonUint(json, ".opcodes.FRAMEDATALOAD.op"), ProbeConstants.OP_FRAMEDATALOAD);
        assertEq(vm.parseJsonUint(json, ".opcodes.SIGPARAM.op"), ProbeConstants.OP_SIGPARAM);
    }

    function test_paramIndicesMatchProbeFile() public view {
        assertEq(vm.parseJsonUint(json, ".txParams.sender"), ProbeConstants.TX_SENDER);
        assertEq(vm.parseJsonUint(json, ".txParams.nonceKeyCount"), ProbeConstants.TX_NONCE_KEY_COUNT);
        assertEq(vm.parseJsonUint(json, ".txParams.nonceKey"), ProbeConstants.TX_NONCE_KEY);
        assertEq(vm.parseJsonUint(json, ".txParams.sequence"), ProbeConstants.TX_SEQUENCE);
        assertEq(vm.parseJsonUint(json, ".txParams.fee"), ProbeConstants.TX_FEE);
        assertEq(vm.parseJsonUint(json, ".txParams.expiry"), ProbeConstants.TX_EXPIRY);
        assertEq(vm.parseJsonUint(json, ".txParams.frameCount"), ProbeConstants.TX_FRAME_COUNT);
        assertEq(vm.parseJsonUint(json, ".txParams.currentFrame"), ProbeConstants.TX_CURRENT_FRAME);
        assertEq(vm.parseJsonUint(json, ".frameParams.mode"), ProbeConstants.FR_MODE);
        assertEq(vm.parseJsonUint(json, ".frameParams.target"), ProbeConstants.FR_TARGET);
        assertEq(vm.parseJsonUint(json, ".frameParams.gasLimit"), ProbeConstants.FR_GAS_LIMIT);
        assertEq(vm.parseJsonUint(json, ".frameParams.stateLimit"), ProbeConstants.FR_STATE_LIMIT);
        assertEq(vm.parseJsonUint(json, ".frameParams.value"), ProbeConstants.FR_VALUE);
        assertEq(vm.parseJsonUint(json, ".frameParams.dataSize"), ProbeConstants.FR_DATA_SIZE);
    }

    function test_economicsMatchProbeFile() public view {
        string memory fmt = vm.parseJsonString(json, ".feeFormat");
        uint8 expected = keccak256(bytes(fmt)) == keccak256("per_gas") ? 1 : 0;
        assertEq(expected, ProbeConstants.FEE_FORMAT);
        assertEq(vm.parseJsonUint(json, ".firstUseKeyStateGas"), ProbeConstants.FIRST_USE_KEY_STATE_GAS);
        assertEq(vm.parseUint(vm.parseJsonString(json, ".sequenceCeiling")), ProbeConstants.SEQUENCE_CEILING);
        assertEq(vm.parseJsonUint(json, ".replacementBumpBps"), ProbeConstants.REPLACEMENT_BUMP_BPS);
        assertEq(vm.parseJsonBool(json, ".pinned"), ProbeConstants.PINNED);
    }
}
