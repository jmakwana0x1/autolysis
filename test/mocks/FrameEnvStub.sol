// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice anvil-only stand-in for HegotaFrameEnv, etched by the gate-a mock frame node so the SENDER
///         frame (selfLiquidate -> env.maxCost()) can be emulated on a chain without frame opcodes.
///         VERIFY is never executed locally (the mock node answers simulate itself).
contract FrameEnvStub {
    function maxCost() external pure returns (uint256) {
        return 0.005 ether;
    }

    function approve(uint256) external pure {}

    fallback() external {
        revert("FrameEnvStub: frame opcodes are not available on anvil");
    }
}
