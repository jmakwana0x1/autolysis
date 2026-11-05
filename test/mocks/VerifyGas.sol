// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

/// @notice The one way VERIFY gas is measured on the mock (A1): cool every contract, slot and
///         frame-opcode helper VERIFY may touch, then re-warm only the account address (a frame's
///         target is warm, like tx.to). This is what a fresh frame transaction sees, PROVIDED the
///         MockFrameEnv helpers were etched in an earlier tx (e.g. `env.set` in setUp): an account
///         created/etched in the measured tx cannot be cooled (A1_verify_gas does this). MOCK ONLY: the
///         devnet number is frames[0].gasUsed from ethrex_simulateFrameTransaction.
library VerifyGas {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function coolAll(address env, address account, address[] memory others) internal {
        string[4] memory tags = ["txparam", "frameparam", "framedataload", "approve"];
        for (uint256 i; i < tags.length; ++i) {
            vm.cool(address(uint160(uint256(keccak256(abi.encode(env, tags[i]))))));
        }
        vm.cool(env);
        vm.cool(account);
        for (uint256 i; i < others.length; ++i) {
            vm.cool(others[i]);
        }
        account.balance; // re-warm the frame target address only; its storage stays cold
    }
}
