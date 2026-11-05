// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HegotaSupport, Devnet, Scope, TxParam, FrameParam} from "@forshtat/hegota-support/contracts/HegotaSupport.sol";

/// @title ProbeOpcodes
/// @notice Deployed on the devnet so `just probe` can confirm the frame opcodes work on chain 1337. Each
///         function executes one opcode and returns/emits what it read, so a probe can compare it to the
///         transaction it submitted. `verify()` runs the reads and then APPROVE, exercising the VERIFY
///         path a staked sender uses. Inherits HegotaSupport, so it owns no opcode bytes.
contract ProbeOpcodes is HegotaSupport {
    event MaxCost(uint256 maxCost);
    event Probed(address sender, uint256 frame0Mode, bytes32 frame1Word0);

    constructor() HegotaSupport(Devnet.ERC8421_WORKSHOP) {}

    function senderParam() external view returns (address) {
        return address(uint160(txparam(TxParam.SENDER)));
    }

    function frameMode(uint256 i) external view returns (uint256) {
        return frameparam(i, FrameParam.MODE);
    }

    function dataWord(uint256 i) external view returns (bytes32) {
        return framedataload(0, i);
    }

    /// @notice Emit MAX_COST (TXPARAM 0x06) so a SENDER frame's receipt log reveals the fee format.
    function emitMaxCost() external {
        emit MaxCost(txparam(TxParam.MAX_COST));
    }

    /// @notice A VERIFY-frame body: read three params, emit them, then APPROVE both scopes.
    function verify() external {
        emit Probed(
            address(uint160(txparam(TxParam.SENDER))), frameparam(0, FrameParam.MODE), framedataload(0, 1)
        );
        approve(Scope.EXECUTION_AND_PAYMENT);
    }
}
