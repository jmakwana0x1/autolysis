// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TxView, CanonicalView} from "../../src/frame/FrameTypes.sol";

/// @notice Reference derivation of the `CanonicalView` the devnet would report for a full `TxView`,
///         with the same early returns as `CanonicalReader`. Tests mutate a `TxView` and check this;
///         `MockFrameEnv` is asserted to agree with it (test/fuzz/FirewallRules.t.sol).
library CanonicalFrom {
    uint256 internal constant EXEC_DATA_LENGTH = 68;

    function from(TxView memory v) internal pure returns (CanonicalView memory c) {
        c.frameCount = v.frames.length;
        c.nonceKeyCount = v.nonceKeys.length;
        if (c.nonceKeyCount != 0) c.nonceKey0 = v.nonceKeys[0];
        c.sequence = v.sequence;
        c.maxCost = v.feeParam;
        if (c.frameCount != 2) return c;
        c.verifyMode = v.frames[0].mode;
        c.verifyAllowedScope = v.frames[0].allowedScope;
        c.verifyStateLimit = v.frames[0].stateLimit;
        c.execMode = v.frames[1].mode;
        c.execTarget = v.frames[1].target;
        c.execValue = v.frames[1].value;
        c.execDataLength = v.frames[1].data.length;
        if (c.execDataLength != EXEC_DATA_LENGTH) return c;
        c.execWord0 = word(v.frames[1].data, 0);
        c.execWord1 = word(v.frames[1].data, 32);
        c.execWord2 = word(v.frames[1].data, 64);
    }

    /// FRAMEDATALOAD semantics: the 32 bytes at `off`, zero-padded past the end.
    function word(bytes memory data, uint256 off) internal pure returns (bytes32 w) {
        for (uint256 k; k < 32; ++k) {
            if (off + k < data.length) w |= bytes32(uint256(uint8(data[off + k])) << (8 * (31 - k)));
        }
    }
}
