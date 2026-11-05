// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Shared types for frame transactions (EIP-8141 style, as run by the Hegota devnet sidecar).
/// @dev Everything the firewall needs from a frame transaction is copied into a `TxView` so the
///      rules can be a pure function. The view is produced either from real opcodes (devnet) or
///      from the Foundry mock.
library FrameTypes {
    uint8 internal constant MODE_DEFAULT = 0;
    uint8 internal constant MODE_VERIFY = 1;
    uint8 internal constant MODE_SENDER = 2;

    /// Fee format settled by probe #2: does TXPARAM 0x06 return the total cost or a per-gas price?
    uint8 internal constant FEE_TOTAL_COST = 0;
    uint8 internal constant FEE_PER_GAS = 1;

    /// APPROVE scopes (draft numbering; probe #1 confirms).
    uint256 internal constant APPROVE_EXECUTION = 0;
    uint256 internal constant APPROVE_PAYMENT = 1;
    uint256 internal constant APPROVE_BOTH = 2;
}

struct FrameView {
    uint8 mode;
    address target;
    uint256 gasLimit;
    uint256 stateLimit;
    uint256 value;
    bytes data;
}

struct TxView {
    address sender;
    uint256[] nonceKeys;
    uint256 sequence;
    /// Raw TXPARAM fee field, interpreted with the probed fee format.
    uint256 feeParam;
    uint256 expiry;
    uint256 currentFrame;
    FrameView[] frames;
}
