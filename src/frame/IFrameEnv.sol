// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TxView} from "./FrameTypes.sol";

/// @title IFrameEnv
/// @notice The single door through which Autolysis reads frame-transaction context.
/// @dev Two implementations exist:
///      - `HegotaFrameEnv`: forwards to a raw-bytecode helper that executes the real frame opcodes
///        (APPROVE, TXPARAM, FRAMEPARAM, FRAMEDATALOAD, SIGPARAM) on the devnet.
///      - `MockFrameEnv` (test/): an injected mock so Forge can fuzz the whole firewall locally,
///        even though Forge's EVM cannot execute frame opcodes.
///      `approve` is always reached through DELEGATECALL from the account, because APPROVE is only
///      valid when ADDRESS equals the frame target (the account). Reads are plain STATICCALLs.
interface IFrameEnv {
    /// @notice Snapshot of the transaction currently being validated / executed.
    function load() external view returns (TxView memory);

    /// @notice Executes APPROVE(scope). MUST be invoked via DELEGATECALL from the approving account.
    function approve(uint256 scope) external;
}
