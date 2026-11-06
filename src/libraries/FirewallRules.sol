// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CanonicalView, FrameTypes} from "../frame/FrameTypes.sol";
import {ProbeConstants} from "../generated/ProbeConstants.sol";

/// @title FirewallRules
/// @notice Pure decision for VERIFY: does this frame transaction match the one canonical shape allowed
///         for liquidating (position, step)? Any single mutation of a field it reads must flip the answer
///         to reject. It reads the fixed-size `CanonicalView`; the fields it leaves to APPROVE / the
///         protocol are listed on `CanonicalView` (FrameTypes.sol).
/// @dev Keeps no state. The account supplies the on-chain expectations (`Expect`), the `FrameEnv`
///      supplies what was actually submitted.
library FirewallRules {
    bytes4 internal constant VERIFY_SEL = 0x3ad51b8d; // bytes4(keccak256("verifyLiquidation()"))
    bytes4 internal constant EXECUTE_SEL = 0xf3ab9cad; // bytes4(keccak256("selfLiquidate(uint256,uint256)"))
    uint256 internal constant EXEC_DATA_LENGTH = 4 + 32 + 32;

    /// @dev Ordinals are part of the `Rejected(reason)` ABI the kit decodes: append only, never reorder.
    enum Reject {
        OK,
        FRAME_COUNT,
        VERIFY_FRAME, // frame 0 not in VERIFY mode (its target/selector are implied by APPROVE)
        EXEC_FRAME_MODE,
        EXEC_TARGET,
        EXEC_SELECTOR,
        EXEC_CALLDATA_LEN,
        POSITION_ID,
        ROUND_ID,
        KEY_COUNT,
        KEY_VALUE,
        KEY_TOP_BYTE,
        SECOND_KEY,
        FEE_CAP,
        STATE_BUDGET,
        ALLOWED_SCOPE,
        SENDER, // unused since A1: sender == account is implied by APPROVE (see CanonicalView)
        EXEC_VALUE
    }

    struct Expect {
        address account; // frame 1 target
        address market;
        uint256 positionId;
        uint256 roundId;
        uint256 feeCapTotal; // max total cost (devnet gas-token units)
        uint256 firstUseStateCost; // ProbeConstants.FIRST_USE_KEY_STATE_GAS when the key is new
        bool keyIsNew; // first use of this nonce key
    }

    /// @notice The nonce key for a (market, position): H(market, id) with the top byte cleared.
    function nonceKey(address market, uint256 positionId) internal pure returns (uint256) {
        uint256 h = uint256(keccak256(abi.encode(market, positionId)));
        return h & ((uint256(1) << 248) - 1); // zero top byte
    }

    /// @notice (positionId, roundId) from the execute frame's three calldata words
    ///         selector(4) ++ positionId(32) ++ roundId(32).
    function execArgs(CanonicalView memory c) internal pure returns (uint256 positionId, uint256 roundId) {
        positionId = (uint256(c.execWord0) << 32) | (uint256(c.execWord1) >> 224);
        roundId = (uint256(c.execWord1) << 32) | (uint256(c.execWord2) >> 224);
    }

    /// @notice Returns Reject.OK iff `c` is the canonical liquidation transaction for `e`.
    function check(CanonicalView memory c, Expect memory e) internal pure returns (Reject) {
        // Exactly two frames: VERIFY then SENDER-execute.
        if (c.frameCount != 2) return Reject.FRAME_COUNT;

        // Frame 0 is the VERIFY frame and may approve both execution and payment (the account self-pays).
        if (c.verifyMode != FrameTypes.MODE_VERIFY) return Reject.VERIFY_FRAME;
        if (c.verifyAllowedScope != FrameTypes.SCOPE_EXECUTION_AND_PAYMENT) return Reject.ALLOWED_SCOPE;

        // Frame 1: SENDER mode, targets the account, moves no value, calls selfLiquidate(pos, round).
        if (c.execMode != FrameTypes.MODE_SENDER) return Reject.EXEC_FRAME_MODE;
        if (c.execTarget != e.account) return Reject.EXEC_TARGET;
        if (c.execValue != 0) return Reject.EXEC_VALUE;
        if (c.execDataLength != EXEC_DATA_LENGTH) return Reject.EXEC_CALLDATA_LEN;
        if (bytes4(c.execWord0) != EXECUTE_SEL) return Reject.EXEC_SELECTOR;

        (uint256 posId, uint256 roundId) = execArgs(c);
        if (posId != e.positionId) return Reject.POSITION_ID;
        if (roundId != e.roundId) return Reject.ROUND_ID;

        // Exactly one nonce key, equal to H(market,id) with zero top byte.
        if (c.nonceKeyCount != 1) return c.nonceKeyCount > 1 ? Reject.SECOND_KEY : Reject.KEY_COUNT;
        if (c.nonceKey0 != nonceKey(e.market, e.positionId)) return Reject.KEY_VALUE;
        if (c.nonceKey0 >> 248 != 0) return Reject.KEY_TOP_BYTE;

        // The keyed nonce order is enforced by the protocol (EIP-8250), not by the firewall (C2).

        // Fee cap on MAX_COST, total-cost format. The view carries no gas limits, so a per-gas fee format
        // cannot be checked: fail closed if the probe ever reports one.
        if (ProbeConstants.FEE_FORMAT != FrameTypes.FEE_TOTAL_COST) return Reject.FEE_CAP;
        if (c.maxCost > e.feeCapTotal) return Reject.FEE_CAP;

        // First-use state budget: the VERIFY frame must fund the new-key charge.
        if (e.keyIsNew && c.verifyStateLimit < e.firstUseStateCost) return Reject.STATE_BUDGET;

        return Reject.OK;
    }
}
