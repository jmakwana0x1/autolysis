// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IFrameEnv} from "../frame/IFrameEnv.sol";
import {TxView, FrameTypes} from "../frame/FrameTypes.sol";
import {FirewallRules} from "../libraries/FirewallRules.sol";
import {ProbeConstants} from "../generated/ProbeConstants.sol";
import {AutolysisMarket} from "./AutolysisMarket.sol";

/// @title AutolysisAccount
/// @notice The on-chain account that validates each liquidation (VERIFY) and pays for it (self-paid).
///         Guarantees: VERIFY approves exactly the canonical shape (delegated to FirewallRules); the
///         never-revert envelope around execution means a failed liquidation returns cleanly and bills
///         at most the failed-attempt cap, so it can never drain the gas tank.
/// @dev `verify()` runs in the VERIFY frame and reaches APPROVE through DELEGATECALL into the FrameEnv
///      (APPROVE requires ADDRESS == the account). `execute()` runs in the SENDER frame.
contract AutolysisAccount {
    IFrameEnv public immutable env;
    AutolysisMarket public market;
    address public owner;

    /// Fee cap in the devnet gas-token unit (same unit as TXPARAM 0x06), per probe #2's fee format.
    uint256 public feeCapTotal = 1_000_000 gwei;
    /// Failed-attempt billing cap in debt-token units (what the tank is billed on failure).
    uint256 public failedAttemptCap;

    error NotOwner();
    error NotSelf();
    error Rejected(FirewallRules.Reject reason);

    event Approved(uint256 positionId, uint256 roundId);
    event LiquidationOk(uint256 indexed positionId, uint256 debtRepaid, uint256 collateralSold, uint256 fee);
    event LiquidationFailed(uint256 indexed positionId, uint256 fee);

    constructor(IFrameEnv env_) {
        env = env_;
        owner = msg.sender;
    }

    function initialize(AutolysisMarket market_, uint256 failedCap_) external {
        if (msg.sender != owner) revert NotOwner();
        market = market_;
        failedAttemptCap = failedCap_;
    }

    function setFeeCap(uint256 cap) external {
        if (msg.sender != owner) revert NotOwner();
        feeCapTotal = cap;
    }

    /// @notice VERIFY frame entry point. Reverts (rejecting the tx) unless the submitted frame tx is
    ///         exactly the canonical liquidation for a currently-unhealthy position; otherwise approves.
    function verify() external {
        TxView memory v = env.load();

        // The execute frame carries (positionId, roundId); decode to build on-chain expectations.
        (uint256 positionId, uint256 roundId) = _decodeExecuteArgs(v);

        FirewallRules.Expect memory e;
        e.account = address(this);
        e.market = address(market);
        e.positionId = positionId;
        e.roundId = roundId;
        e.feeCapTotal = feeCapTotal;
        e.firstUseStateCost = ProbeConstants.FIRST_USE_KEY_STATE_GAS;
        e.keyIsNew = v.sequence == 0; // first use of the key is sequence 0, not count 0 (C2)

        FirewallRules.Reject r = FirewallRules.check(v, e);
        if (r != FirewallRules.Reject.OK) revert Rejected(r);

        // Economic gate: only approve when the position is actually liquidatable right now.
        if (market.healthFactor(positionId) >= 1e18) revert Rejected(FirewallRules.Reject.OK);

        // APPROVE via DELEGATECALL so ADDRESS stays equal to this account (APPROVE is only valid when
        // the executing address is the frame target).
        (bool ok,) = address(env)
            .delegatecall(abi.encodeWithSelector(IFrameEnv.approve.selector, FrameTypes.SCOPE_EXECUTION_AND_PAYMENT));
        require(ok, "approve failed");
        emit Approved(positionId, roundId);
    }

    /// @notice SENDER frame entry point: the never-revert envelope. Runs one gradual liquidation step;
    ///         on any failure it bills the failed-attempt cap and returns cleanly.
    function execute(uint256 positionId, uint256 roundId) external {
        // In a SENDER frame the caller is tx.sender, which is this account itself. Nothing else may
        // call execute, or a stranger could loop failing attempts and bill the borrower's tank (C1).
        if (msg.sender != address(this)) revert NotSelf();
        // Reservation guards the tank; if it can't back an attempt, do nothing (no revert, no bill).
        if (market.tankHeadroom(positionId, failedAttemptCap) == 0) return;
        market.reserveAttempt(positionId);

        try market.executeLiquidation(positionId, roundId, failedAttemptCap) returns (
            uint256 debtRepaid, uint256 collateralSold, uint256 fee
        ) {
            emit LiquidationOk(positionId, debtRepaid, collateralSold, fee);
        } catch {
            // Failure path: bill at most the failed-attempt cap, release the reservation, return clean.
            market.billFailedAttempt(positionId, failedAttemptCap);
            emit LiquidationFailed(positionId, failedAttemptCap);
        }
    }

    function _decodeExecuteArgs(TxView memory v) internal pure returns (uint256 positionId, uint256 roundId) {
        // The execute frame is frame 1 in the canonical shape; guard length before decoding.
        require(v.frames.length == 2, "shape");
        bytes memory d = v.frames[1].data;
        require(d.length == 4 + 64, "args");
        assembly {
            positionId := mload(add(d, 36))
            roundId := mload(add(d, 68))
        }
    }
}
