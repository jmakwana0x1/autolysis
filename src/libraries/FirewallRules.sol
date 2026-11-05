// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TxView, FrameView, FrameTypes} from "../frame/FrameTypes.sol";
import {ProbeConstants} from "../generated/ProbeConstants.sol";

/// @title FirewallRules
/// @notice Pure decision for VERIFY: does this frame transaction match the one canonical shape allowed
///         for liquidating (position, step)? One guarantee: approves exactly one transaction shape per
///         (position, step). Any single mutation of the canonical tx must flip the answer to reject.
/// @dev Keeps no state. The account supplies the on-chain expectations (`Expect`), the `FrameEnv`
///      supplies what was actually submitted (`TxView`).
library FirewallRules {
    /// @dev selector of AutolysisAccount.verify() and execute(uint256,uint256); kept here so the rule
    ///      is self-contained and fuzzable without deploying the account.
    bytes4 internal constant VERIFY_SEL = 0x3ad51b8d; // bytes4(keccak256("verifyLiquidation()"))
    bytes4 internal constant EXECUTE_SEL = 0xf3ab9cad; // bytes4(keccak256("selfLiquidate(uint256,uint256)"))

    enum Reject {
        OK,
        FRAME_COUNT,
        VERIFY_FRAME,
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
        SENDER
    }

    struct Expect {
        address account; // frame target for both frames; tx sender
        address market;
        uint256 positionId;
        uint256 roundId;
        uint256 feeCapTotal; // max total cost (debt units of the devnet gas token), per fee format
        uint256 firstUseStateCost; // ProbeConstants.FIRST_USE_KEY_STATE_GAS when the key is new
        bool keyIsNew; // first use of this nonce key
    }

    /// @notice The nonce key for a (market, position): H(market, id) with the top byte cleared.
    function nonceKey(address market, uint256 positionId) internal pure returns (uint256) {
        uint256 h = uint256(keccak256(abi.encode(market, positionId)));
        return h & ((uint256(1) << 248) - 1); // zero top byte
    }

    /// @notice Returns Reject.OK iff `v` is exactly the canonical liquidation transaction for `e`.
    function check(TxView memory v, Expect memory e) internal pure returns (Reject) {
        // Sender must be the account itself (self-paid).
        if (v.sender != e.account) return Reject.SENDER;

        // Exactly two frames: VERIFY then SENDER-execute.
        if (v.frames.length != 2) return Reject.FRAME_COUNT;

        FrameView memory vf = v.frames[0];
        FrameView memory xf = v.frames[1];

        // Frame 0: VERIFY mode, targets the account, calls verify() with empty args, and is allowed to
        // approve both execution and payment (so the account can self-pay).
        if (vf.mode != FrameTypes.MODE_VERIFY) return Reject.VERIFY_FRAME;
        if (vf.target != e.account) return Reject.VERIFY_FRAME;
        if (vf.data.length != 4 || bytes4(vf.data) != VERIFY_SEL) return Reject.VERIFY_FRAME;
        if (vf.allowedScope != FrameTypes.SCOPE_EXECUTION_AND_PAYMENT) return Reject.ALLOWED_SCOPE;

        // Frame 1: SENDER mode, targets the account.
        if (xf.mode != FrameTypes.MODE_SENDER) return Reject.EXEC_FRAME_MODE;
        if (xf.target != e.account) return Reject.EXEC_TARGET;
        if (xf.data.length != 4 + 32 + 32) return Reject.EXEC_CALLDATA_LEN;
        if (bytes4(xf.data) != EXECUTE_SEL) return Reject.EXEC_SELECTOR;

        (uint256 posId, uint256 roundId) = _decodeTwo(xf.data);
        if (posId != e.positionId) return Reject.POSITION_ID;
        if (roundId != e.roundId) return Reject.ROUND_ID;

        // Exactly one nonce key, equal to H(market,id) with zero top byte.
        if (v.nonceKeys.length != 1) return v.nonceKeys.length > 1 ? Reject.SECOND_KEY : Reject.KEY_COUNT;
        uint256 expectedKey = nonceKey(e.market, e.positionId);
        if (v.nonceKeys[0] != expectedKey) return Reject.KEY_VALUE;
        if (v.nonceKeys[0] >> 248 != 0) return Reject.KEY_TOP_BYTE;

        // The keyed nonce order is enforced by the protocol (EIP-8250), not by the firewall: a failed
        // attempt burns the nonce without advancing the liquidation count, so the firewall must not tie
        // the submitted sequence to that count (C2). `keyIsNew` is derived from the sequence itself.

        // Fee cap, in the probed fee format.
        uint256 totalGas = vf.gasLimit + xf.gasLimit;
        uint256 feeTotal = ProbeConstants.FEE_FORMAT == FrameTypes.FEE_PER_GAS ? v.feeParam * totalGas : v.feeParam;
        if (feeTotal > e.feeCapTotal) return Reject.FEE_CAP;

        // First-use state budget: the VERIFY frame must fund the new-key charge.
        if (e.keyIsNew && vf.stateLimit < e.firstUseStateCost) return Reject.STATE_BUDGET;

        return Reject.OK;
    }

    function _decodeTwo(bytes memory data) private pure returns (uint256 a, uint256 b) {
        assembly {
            a := mload(add(data, 36)) // 32 len + 4 selector
            b := mload(add(data, 68))
        }
    }
}
