// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CanonicalView} from "./FrameTypes.sol";
import {ProbeConstants} from "../generated/ProbeConstants.sol";

/// @title CanonicalReader
/// @notice The one implementation of `loadCanonical()`, shared by the devnet env and the Foundry mock,
///         so local tests run the exact read sequence the devnet runs. Subclasses supply the three raw
///         reads (TXPARAM, FRAMEPARAM, FRAMEDATALOAD). Parameter ids come from the probed constants.
abstract contract CanonicalReader {
    uint256 internal constant EXEC_DATA_LENGTH = 4 + 32 + 32;

    function _txparam(uint256 id) internal view virtual returns (uint256);
    function _frameparam(uint256 frameIndex, uint256 id) internal view virtual returns (uint256);
    function _framedataload(uint256 offset, uint256 frameIndex) internal view virtual returns (bytes32);

    function _loadCanonical() internal view returns (CanonicalView memory c) {
        c.frameCount = _txparam(ProbeConstants.TX_FRAME_COUNT);
        c.nonceKeyCount = _txparam(ProbeConstants.TX_NONCE_KEY_COUNT);
        if (c.nonceKeyCount != 0) c.nonceKey0 = _txparam(ProbeConstants.TX_NONCE_KEY_0);
        c.sequence = _txparam(ProbeConstants.TX_NONCE);
        c.maxCost = _txparam(ProbeConstants.TX_MAX_COST);
        if (c.frameCount != 2) return c; // rejected on FRAME_COUNT; frame 1 may not exist

        c.verifyAllowedScope = _frameparam(0, ProbeConstants.FR_ALLOWED_SCOPE);
        c.verifyStateLimit = _frameparam(0, ProbeConstants.FR_STATE_GAS_LIMIT);
        c.execMode = _frameparam(1, ProbeConstants.FR_MODE);
        c.execTarget = address(uint160(_frameparam(1, ProbeConstants.FR_RESOLVED_TARGET)));
        c.execValue = _frameparam(1, ProbeConstants.FR_VALUE);
        c.execDataLength = _frameparam(1, ProbeConstants.FR_DATA_LENGTH);
        if (c.execDataLength != EXEC_DATA_LENGTH) return c; // rejected on EXEC_CALLDATA_LEN
        c.execWord0 = _framedataload(0, 1);
        c.execWord1 = _framedataload(32, 1);
        c.execWord2 = _framedataload(64, 1);
    }
}
