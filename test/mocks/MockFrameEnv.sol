// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IFrameEnv} from "../../src/frame/IFrameEnv.sol";
import {TxView} from "../../src/frame/FrameTypes.sol";

/// @notice Foundry stand-in for the frame opcodes. Tests write a `TxView`; the account reads it back
///         through the same `IFrameEnv` door it uses on the devnet. Models keyed-nonce consumption:
///         the per-key sequence advances at APPROVE, exactly like the devnet, so a failed attempt
///         still burns the nonce even though the market's liquidation count does not move (C2).
contract MockFrameEnv is IFrameEnv {
    bytes internal current;
    address private immutable SELF;

    /// account => scope + 1 (0 means "no APPROVE in this transaction")
    mapping(address => uint256) public approvedScope;
    uint256 public approveCount;
    /// nonce key => next expected sequence (advances on every APPROVE, success or failure)
    mapping(uint256 => uint256) public sequenceOf;

    constructor() {
        SELF = address(this);
    }

    function set(TxView memory v) external {
        current = abi.encode(v);
    }

    function clear() external {
        delete current;
    }

    function resetApprovals(address account) external {
        delete approvedScope[account];
    }

    function load() external view returns (TxView memory v) {
        require(current.length != 0, "MockFrameEnv: no frame tx");
        v = abi.decode(current, (TxView));
    }

    /// @dev Reached through DELEGATECALL from the account, so `address(this)` is the account.
    function approve(uint256 scope) external {
        MockFrameEnv(SELF).record(address(this), scope);
    }

    function record(address account, uint256 scope) external {
        approvedScope[account] = scope + 1;
        approveCount++;
        // Burn the nonce for the submitted tx's key, as the devnet does at APPROVE.
        TxView memory v = abi.decode(current, (TxView));
        if (v.nonceKeys.length == 1) sequenceOf[v.nonceKeys[0]] += 1;
    }

    function isApproved(address account) external view returns (bool) {
        return approvedScope[account] != 0;
    }
}
