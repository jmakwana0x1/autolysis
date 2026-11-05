// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CanonicalView} from "./FrameTypes.sol";

/// @title IFrameEnv
/// @notice The single door through which Autolysis reads frame-transaction context.
/// @dev Two implementations exist, both built on `CanonicalReader` (same read sequence):
///      - `HegotaFrameEnv`: forwards to raw-bytecode helpers that execute the real frame opcodes
///        (APPROVE, TXPARAM, FRAMEPARAM, FRAMEDATALOAD) on the devnet.
///      - `MockFrameEnv` (test/): per-opcode helpers whose answers are constant tables in their code,
///        so Forge can fuzz the firewall locally at a realistic per-read cost.
///      `approve` is always reached through DELEGATECALL from the account, because APPROVE is only
///      valid when ADDRESS equals the frame target (the account). Reads are plain STATICCALLs.
interface IFrameEnv {
    /// @notice The fixed-size slice of the current frame transaction that VERIFY checks.
    function loadCanonical() external view returns (CanonicalView memory);

    /// @notice MAX_COST (TXPARAM 0x06) alone. Used by the SENDER frame so the never-revert envelope
    ///         does not depend on FRAMEPARAM/FRAMEDATALOAD.
    function maxCost() external view returns (uint256);

    /// @notice Executes APPROVE(scope). MUST be invoked via DELEGATECALL from the approving account.
    function approve(uint256 scope) external;
}
