// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Shared types for frame transactions (EIP-8141 / EIP-8250, as run by the Hegota devnet).
/// @dev Everything the firewall needs from a frame transaction is copied into a `TxView` so the
///      rules can be a pure function. The view is produced either from real opcodes via
///      `HegotaFrameEnv` (devnet) or from the Foundry mock. Field ids and scopes mirror
///      hegota-support `contracts/Params.sol` @ 2377188; there is no expiry field (TXPARAM 0x07 is
///      BLOB_COUNT), so freshness comes from the round window, not an expiry.
library FrameTypes {
    // Frame modes (FrameMode enum): DEFAULT 0, VERIFY 1, SENDER 2, POST_TX 3.
    uint8 internal constant MODE_DEFAULT = 0;
    uint8 internal constant MODE_VERIFY = 1;
    uint8 internal constant MODE_SENDER = 2;

    /// Fee format settled by probe #2: does TXPARAM 0x06 (MAX_COST) return the total cost or a per-gas price?
    uint8 internal constant FEE_TOTAL_COST = 0;
    uint8 internal constant FEE_PER_GAS = 1;

    /// APPROVE scopes (Scope enum): NONE 0, PAYMENT 1, EXECUTION 2, EXECUTION_AND_PAYMENT 3.
    uint256 internal constant SCOPE_NONE = 0;
    uint256 internal constant SCOPE_PAYMENT = 1;
    uint256 internal constant SCOPE_EXECUTION = 2;
    uint256 internal constant SCOPE_EXECUTION_AND_PAYMENT = 3;
}

struct FrameView {
    uint8 mode;
    address target; // RESOLVED_TARGET (null target resolves to the sender on chain)
    uint256 gasLimit; // EXECUTION_GAS_LIMIT
    uint256 stateLimit; // STATE_GAS_LIMIT
    uint256 value; // VALUE
    uint256 allowedScope; // ALLOWED_SCOPE (what this frame may approve)
    bytes data;
}

struct TxView {
    address sender;
    uint256[] nonceKeys;
    uint256 sequence; // NONCE (the keyed nonce value)
    uint256 feeParam; // MAX_COST, interpreted with the probed fee format
    uint256 currentFrame; // CURRENT_FRAME_INDEX
    FrameView[] frames;
}
