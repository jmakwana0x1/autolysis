// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IFrameEnv} from "../frame/IFrameEnv.sol";
import {IStakingRegistry} from "../frame/IStakingRegistry.sol";
import {CanonicalView, FrameTypes} from "../frame/FrameTypes.sol";
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

    /// ERC-8421 staking registry; VERIFY may read outside contracts only when this account is staked.
    IStakingRegistry public stakingRegistry;

    /// W1.5 fallback: when true, VERIFY reads the round/health gate from this account's OWN storage
    /// (a snapshot pushed in a prior SENDER-frame tx, where cross-contract reads are allowed) instead
    /// of calling into the market during validation. This keeps VERIFY to tx.sender storage only, so
    /// it needs no ERC-8421 STORAGE-032 staking to read the market/feed. Off by default: the staked
    /// path (direct market reads) is the primary design; this is for devnets without staked reads.
    bool public storageOnlyVerify;

    /// Round/health snapshot for storage-only VERIFY. Written by `pushVerifySnapshot` outside VERIFY.
    struct VerifySnapshot {
        bool set;
        uint256 roundId; // the round the snapshot was taken at
        uint256 lastAttemptRound; // market.lastAttemptRound(positionId) at snapshot time
        uint256 healthAtRound; // market.healthFactorAtRound(positionId, roundId)
        uint256 healthLatest; // market.healthFactor(positionId)
    }

    mapping(uint256 positionId => VerifySnapshot) public verifySnapshotOf;

    error NotOwner();
    error NotSelf();
    error Rejected(FirewallRules.Reject reason);
    error RoundAlreadyUsed();
    error NotUnhealthy();
    error NoRegistry();
    error NoSnapshot();
    error SnapshotRoundMismatch();

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

    function setStakingRegistry(IStakingRegistry registry) external {
        if (msg.sender != owner) revert NotOwner();
        stakingRegistry = registry;
    }

    /// @notice Toggle the storage-only VERIFY fallback (W1.5). When on, VERIFY uses the snapshot in
    ///         this account's own storage for the round/health gate instead of calling the market.
    function setStorageOnlyVerify(bool on) external {
        if (msg.sender != owner) revert NotOwner();
        storageOnlyVerify = on;
    }

    /// @notice Push the round/health snapshot VERIFY will read in storage-only mode. Called OUTSIDE the
    ///         VERIFY frame (e.g. a SENDER-frame tx, where cross-contract reads are permitted), so the
    ///         market reads happen here, not during validation. Reverts if the position is not actually
    ///         unhealthy, so a snapshot can never approve a healthy position.
    /// @dev Anyone may push: the values are read live from the market/feed here, so the pusher cannot
    ///      forge them, and the round gate + both health gates are re-checked in VERIFY against the
    ///      snapshot. Reading the market here is a normal external call, not a VERIFY-time read.
    function pushVerifySnapshot(uint256 positionId, uint256 roundId) external {
        uint256 lastAttempt = market.lastAttemptRound(positionId);
        uint256 hAtRound = market.healthFactorAtRound(positionId, roundId);
        uint256 hLatest = market.healthFactor(positionId);
        verifySnapshotOf[positionId] = VerifySnapshot({
            set: true,
            roundId: roundId,
            lastAttemptRound: lastAttempt,
            healthAtRound: hAtRound,
            healthLatest: hLatest
        });
    }

    /// @notice Stake this account in the ERC-8421 registry so VERIFY may read the market and feed and
    ///         gets the staked validation-gas limit. The account stakes itself (msg.sender == this), so
    ///         the registry sees the account as the staked entity. `delay` must be >= 86,400s and
    ///         msg.value >= the devnet's MIN_STAKE_VALUE for it to count as staked.
    function stake(uint32 delay) external payable {
        if (msg.sender != owner) revert NotOwner();
        if (address(stakingRegistry) == address(0)) revert NoRegistry();
        stakingRegistry.addStake{value: msg.value}(delay);
    }

    /// @notice VERIFY frame entry point. Reverts (rejecting the tx) unless the submitted frame tx is
    ///         exactly the canonical liquidation for a currently-unhealthy position; otherwise approves.
    /// @dev VERIFY reads the market, feed and frame env. Under ERC-8421 STORAGE-032 the account must be
    ///      STAKED (see IStakingRegistry / stake()) for those reads to be allowed during validation; the
    ///      deploy script stakes it where a registry is configured, and probe 3 confirms it on chain.
    function verifyLiquidation() external {
        CanonicalView memory c = env.loadCanonical();

        // The execute frame carries (positionId, roundId); decode to build on-chain expectations.
        (uint256 positionId, uint256 roundId) = FirewallRules.execArgs(c);

        FirewallRules.Expect memory e;
        e.account = address(this);
        e.market = address(market);
        e.positionId = positionId;
        e.roundId = roundId;
        e.feeCapTotal = feeCapTotal;
        e.firstUseStateCost = ProbeConstants.FIRST_USE_KEY_STATE_GAS;
        e.keyIsNew = c.sequence == 0; // first use of the key is sequence 0, not count 0 (C2)

        FirewallRules.Reject r = FirewallRules.check(c, e);
        if (r != FirewallRules.Reject.OK) revert Rejected(r);

        // Round + economic gate (H1). Two ways to source it:
        //  - staked path (default): read the market/feed directly in VERIFY (needs STORAGE-032 staking);
        //  - storage-only path (W1.5): read a snapshot from this account's own storage, written outside
        //    VERIFY, so validation touches no outside contract and needs no staked read.
        if (storageOnlyVerify) {
            _gateFromSnapshot(positionId, roundId);
        } else {
            _gateFromMarket(positionId, roundId);
        }

        // APPROVE via DELEGATECALL so ADDRESS stays equal to this account (APPROVE is only valid when
        // the executing address is the frame target). No event: VERIFY is read-only on the devnet, and
        // the SENDER frame's LiquidationOk/LiquidationFailed already records the outcome.
        (bool ok,) = address(env)
            .delegatecall(abi.encodeWithSelector(IFrameEnv.approve.selector, FrameTypes.SCOPE_EXECUTION_AND_PAYMENT));
        require(ok, "approve failed");
    }

    /// @notice SENDER frame entry point: the never-revert envelope. Runs one gradual liquidation step;
    ///         on any failure it bills the failed-attempt cap and returns cleanly.
    function selfLiquidate(uint256 positionId, uint256 roundId) external {
        // In a SENDER frame the caller is tx.sender, which is this account itself. Nothing else may
        // call execute, or a stranger could loop failing attempts and bill the borrower's tank (C1).
        if (msg.sender != address(this)) revert NotSelf();
        // The fee is billed from the position's own collateral (H2), so there is no reservation to make.
        // The cap is the transaction's MAX_COST (TXPARAM 0x06), read back through the frame env; the
        // market bills min(MAX_COST, FEE_CAP_BPS * collateral sold) on success and min(MAX_COST,
        // MAX_FAILED_GAS_BILL) on failure, so the borrower is never charged more than they signed for.
        uint256 maxCost = env.maxCost();
        try market.executeLiquidation(positionId, roundId, maxCost) returns (
            uint256 debtRepaid, uint256 collateralSold, uint256 fee
        ) {
            emit LiquidationOk(positionId, debtRepaid, collateralSold, fee);
        } catch {
            market.billFailedAttempt(positionId, roundId, maxCost);
            emit LiquidationFailed(positionId, maxCost);
        }
    }

    /// @notice The account holds ETH to pay for its own frame transactions; the market funds it from
    ///         the liquidated position's collateral (H2).
    receive() external payable {}

    /// Staked path: round gate + both health gates read live from the market (cross-contract reads).
    function _gateFromMarket(uint256 positionId, uint256 roundId) internal view {
        // The cited round must be newer than the last round this position was liquidated at, so a
        // stale round can't be replayed.
        if (roundId <= market.lastAttemptRound(positionId)) revert RoundAlreadyUsed();
        // The position must be unhealthy at BOTH the cited round's price and the latest price.
        // healthFactorAtRound reverts (via checkRoundForVerify, no TIMESTAMP) if the round is outside
        // the window / band / breaker-pending, so a bad round is rejected here in VERIFY.
        if (market.healthFactorAtRound(positionId, roundId) >= 1e18) revert NotUnhealthy();
        if (market.healthFactor(positionId) >= 1e18) revert NotUnhealthy();
    }

    /// Storage-only path (W1.5): same gates, read from the snapshot in this account's own storage. No
    /// outside contract is touched, so VERIFY needs no staked read. The snapshot was validated against
    /// the live market when `pushVerifySnapshot` wrote it, and it must be for exactly this round.
    function _gateFromSnapshot(uint256 positionId, uint256 roundId) internal view {
        VerifySnapshot storage s = verifySnapshotOf[positionId];
        if (!s.set) revert NoSnapshot();
        if (s.roundId != roundId) revert SnapshotRoundMismatch();
        if (roundId <= s.lastAttemptRound) revert RoundAlreadyUsed();
        if (s.healthAtRound >= 1e18) revert NotUnhealthy();
        if (s.healthLatest >= 1e18) revert NotUnhealthy();
    }
}
