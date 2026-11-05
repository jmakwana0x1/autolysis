// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ProbeConstants} from "../../src/generated/ProbeConstants.sol";
import {Scope, TxParam, FrameParam} from "@forshtat/hegota-support/contracts/Params.sol";

/// @notice The generated constants must match both deployments/probes.json and the real hegota-support
///         enums (Params.sol @ 2377188). A changed probe result (after `just probe`) or a renumbered
///         draft fails this test until `just gen` regenerates. This is the C5 guard: the frame layer
///         owns no opcode bytes or param ids of its own.
contract ProbeConstantsTest is Test {
    string internal json;

    function setUp() public {
        json = vm.readFile("deployments/probes.json");
    }

    function test_paramIdsMatchHegotaEnums() public pure {
        assertEq(ProbeConstants.TX_NONCE, uint256(TxParam.NONCE));
        assertEq(ProbeConstants.TX_SENDER, uint256(TxParam.SENDER));
        assertEq(ProbeConstants.TX_MAX_COST, uint256(TxParam.MAX_COST));
        assertEq(ProbeConstants.TX_FRAME_COUNT, uint256(TxParam.FRAME_COUNT));
        assertEq(ProbeConstants.TX_CURRENT_FRAME_INDEX, uint256(TxParam.CURRENT_FRAME_INDEX));
        assertEq(ProbeConstants.TX_STATE_GAS_LEFT, uint256(TxParam.STATE_GAS_LEFT));
        assertEq(ProbeConstants.TX_NONCE_KEY_COUNT, uint256(TxParam.NONCE_KEY_COUNT));
        assertEq(ProbeConstants.TX_NONCE_KEYS_HASH, uint256(TxParam.NONCE_KEYS_HASH));
        assertEq(ProbeConstants.TX_NONCE_KEY_0, uint256(TxParam.NONCE_KEY_0));

        assertEq(ProbeConstants.FR_RESOLVED_TARGET, uint256(FrameParam.RESOLVED_TARGET));
        assertEq(ProbeConstants.FR_EXECUTION_GAS_LIMIT, uint256(FrameParam.EXECUTION_GAS_LIMIT));
        assertEq(ProbeConstants.FR_MODE, uint256(FrameParam.MODE));
        assertEq(ProbeConstants.FR_FLAGS, uint256(FrameParam.FLAGS));
        assertEq(ProbeConstants.FR_DATA_LENGTH, uint256(FrameParam.DATA_LENGTH));
        assertEq(ProbeConstants.FR_STATUS, uint256(FrameParam.STATUS));
        assertEq(ProbeConstants.FR_ALLOWED_SCOPE, uint256(FrameParam.ALLOWED_SCOPE));
        assertEq(ProbeConstants.FR_ATOMIC_BATCH, uint256(FrameParam.ATOMIC_BATCH));
        assertEq(ProbeConstants.FR_VALUE, uint256(FrameParam.VALUE));
        assertEq(ProbeConstants.FR_STATE_GAS_LIMIT, uint256(FrameParam.STATE_GAS_LIMIT));
    }

    function test_scopesMatchHegotaEnums() public pure {
        assertEq(ProbeConstants.SCOPE_NONE, uint256(Scope.NONE));
        assertEq(ProbeConstants.SCOPE_PAYMENT, uint256(Scope.PAYMENT));
        assertEq(ProbeConstants.SCOPE_EXECUTION, uint256(Scope.EXECUTION));
        assertEq(ProbeConstants.SCOPE_EXECUTION_AND_PAYMENT, uint256(Scope.EXECUTION_AND_PAYMENT));
    }

    function test_opcodeBytesMatchHegotaEnum() public pure {
        // The Opcode enum is symbolic (names, not bytes); assert the documented tracer opcode bytes.
        assertEq(ProbeConstants.OP_APPROVE, 0xaa);
        assertEq(ProbeConstants.OP_TXPARAM, 0xb0);
        assertEq(ProbeConstants.OP_FRAMEDATALOAD, 0xb1);
        assertEq(ProbeConstants.OP_FRAMEPARAM, 0xb3);
        assertEq(ProbeConstants.OP_SIGPARAM, 0xb4);
    }

    function test_matchesProbeFile() public view {
        assertEq(vm.parseJsonUint(json, ".txParams.NONCE"), ProbeConstants.TX_NONCE);
        assertEq(vm.parseJsonUint(json, ".txParams.MAX_COST"), ProbeConstants.TX_MAX_COST);
        assertEq(vm.parseJsonUint(json, ".frameParams.ALLOWED_SCOPE"), ProbeConstants.FR_ALLOWED_SCOPE);
        assertEq(vm.parseJsonUint(json, ".scopes.EXECUTION_AND_PAYMENT"), ProbeConstants.SCOPE_EXECUTION_AND_PAYMENT);
        assertEq(vm.parseJsonUint(json, ".firstUseKeyStateGas"), ProbeConstants.FIRST_USE_KEY_STATE_GAS);
        string memory fmt = vm.parseJsonString(json, ".feeFormat");
        uint8 expected = keccak256(bytes(fmt)) == keccak256("per_gas") ? 1 : 0;
        assertEq(expected, ProbeConstants.FEE_FORMAT);
    }
}
