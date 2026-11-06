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

/// @notice The FIXED-size slice of a frame transaction that VERIFY actually checks (A1, PLAN-v4.4).
/// @dev Read by `IFrameEnv.loadCanonical()` with 15 frame-opcode reads and no dynamic ABI encoding.
///      Fields that the firewall no longer reads, and why that is safe:
///      - sender, frame 0 target: APPROVE(EXECUTION[_AND_PAYMENT]) requires the executing address to be
///        the frame's resolved target and that target to be tx.sender (EIP-8141 §APPROVE, as cited in
///        lib/mempool-workshop-sidecar/docs/plans/2026-09-02-erc7562-native-aa-mempool-spec.md:66), so a
///        successful APPROVE from this account already implies both equal the account.
///      - frame 0 selector: the account has no other entry that reaches APPROVE.
///      - current frame index: with exactly 2 frames, frame 0 in VERIFY mode and frame 1 in SENDER
///        mode, the approving frame is frame 0. (Frame 0 MODE itself IS read: that APPROVE is
///        VERIFY-only is not confirmed in vendored source, so the rules check it explicitly.)
///      - frame gas limits: the fee cap uses MAX_COST in the total-cost format (probe #2, FEE_FORMAT=0).
///      When frameCount != 2 the frame fields are left zero (the rules reject on FRAME_COUNT first);
///      when exec data length != 68 the words are left zero (rejected on EXEC_CALLDATA_LEN).
struct CanonicalView {
    uint256 frameCount; // TXPARAM FRAME_COUNT
    uint256 verifyMode; // FRAMEPARAM(0, MODE)
    uint256 verifyAllowedScope; // FRAMEPARAM(0, ALLOWED_SCOPE)
    uint256 verifyStateLimit; // FRAMEPARAM(0, STATE_GAS_LIMIT)
    uint256 execMode; // FRAMEPARAM(1, MODE)
    address execTarget; // FRAMEPARAM(1, RESOLVED_TARGET)
    uint256 execValue; // FRAMEPARAM(1, VALUE)
    uint256 execDataLength; // FRAMEPARAM(1, DATA_LENGTH)
    bytes32 execWord0; // FRAMEDATALOAD(0, 1): selector ++ positionId[0:28]
    bytes32 execWord1; // FRAMEDATALOAD(32, 1): positionId[28:32] ++ roundId[0:28]
    bytes32 execWord2; // FRAMEDATALOAD(64, 1): roundId[28:32] ++ padding
    uint256 nonceKeyCount; // TXPARAM NONCE_KEY_COUNT
    uint256 nonceKey0; // TXPARAM NONCE_KEY_0 (0 when there is no key)
    uint256 sequence; // TXPARAM NONCE (the keyed nonce value)
    uint256 maxCost; // TXPARAM MAX_COST
}

/// @notice Full view of a frame transaction. No longer read on chain; kept as the authoring format for
///         tests (MockFrameEnv derives the CanonicalView from it) and off-chain tooling.
struct TxView {
    address sender;
    uint256[] nonceKeys;
    uint256 sequence; // NONCE (the keyed nonce value)
    uint256 feeParam; // MAX_COST, interpreted with the probed fee format
    uint256 currentFrame; // CURRENT_FRAME_INDEX
    FrameView[] frames;
}
