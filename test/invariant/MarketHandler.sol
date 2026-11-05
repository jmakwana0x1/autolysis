// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AutolysisMarket} from "../../src/core/AutolysisMarket.sol";
import {AutolysisAccount} from "../../src/core/AutolysisAccount.sol";
import {RoundFeed} from "../../src/core/RoundFeed.sol";
import {FirewallRules} from "../../src/libraries/FirewallRules.sol";
import {TxView, FrameView, FrameTypes} from "../../src/frame/FrameTypes.sol";
import {ProbeConstants} from "../../src/generated/ProbeConstants.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MockFrameEnv} from "../mocks/MockFrameEnv.sol";

/// @notice Randomly calls borrow, repay, deposit, withdraw, price update, liquidation through the
///         account, direct liquidation from a stranger, and tank refills. Tracks ghost totals so the
///         invariants can check conservation.
contract MarketHandler is Test {
    AutolysisMarket public market;
    AutolysisAccount public account;
    RoundFeed public feed;
    MockFrameEnv public env;
    MockWETH public col;
    MockERC20 public usdc;

    uint256[] public posIds;
    mapping(uint256 => bool) public known;

    // ghosts
    uint256 public ghostDeposits; // total USDC deposited to tanks
    uint256 public strangerLiquidationReverts;
    uint256 public successfulSteps;
    uint256 public sawUnhealthy;
    uint256 public verifyReverted;
    uint256 public strangerExecuteBilled; // must stay 0 (C1)

    address constant ALICE = address(0xA11CE);
    address constant STRANGER = address(0x5748);

    constructor(AutolysisMarket m, AutolysisAccount a, RoundFeed f, MockFrameEnv e, MockWETH c, MockERC20 u) {
        market = m;
        account = a;
        feed = f;
        env = e;
        col = c;
        usdc = u;
    }

    function _pos(uint256 seed) internal view returns (uint256) {
        if (posIds.length == 0) return 0;
        return posIds[seed % posIds.length];
    }

    function openAndFund(uint256 colAmt, uint256 borrowAmt) public {
        colAmt = bound(colAmt, 1e18, 1_000e18);
        vm.startPrank(ALICE);
        uint256 id = market.open();
        col.mint(ALICE, colAmt);
        col.approve(address(market), type(uint256).max);
        market.deposit(id, colAmt);
        // borrow up to ~80% of max to stay healthy initially
        uint256 price = feed.getRound(feed.latestRound()).price;
        uint256 maxDebt = colAmt * price / 1e18 * market.liqThreshold() / 1e18;
        borrowAmt = bound(borrowAmt, maxDebt == 0 ? 0 : maxDebt * 90 / 100, maxDebt == 0 ? 0 : maxDebt * 99 / 100);
        if (borrowAmt > 0) market.borrow(id, borrowAmt);
        // fund tank
        usdc.mint(ALICE, 1e18);
        usdc.approve(address(market), type(uint256).max);
        vm.stopPrank();
        ghostDeposits += 1e18;
        posIds.push(id);
        known[id] = true;
    }

    function deposit(uint256 seed, uint256 amt) public {
        uint256 id = _pos(seed);
        if (id == 0) return;
        amt = bound(amt, 1, 100e18);
        vm.startPrank(ALICE);
        col.mint(ALICE, amt);
        col.approve(address(market), type(uint256).max);
        market.deposit(id, amt);
        vm.stopPrank();
    }

    function repay(uint256 seed, uint256 amt) public {
        uint256 id = _pos(seed);
        if (id == 0) return;
        (,, uint256 debt,) = market.positions(id);
        if (debt == 0) return;
        amt = bound(amt, 1, debt);
        vm.startPrank(ALICE);
        usdc.mint(ALICE, amt);
        usdc.approve(address(market), type(uint256).max);
        market.repay(id, amt);
        vm.stopPrank();
    }

    function refillTank(uint256 seed, uint256 amt) public {
        uint256 id = _pos(seed);
        if (id == 0) return;
        amt = bound(amt, 1, 1e18);
        vm.startPrank(ALICE);
        usdc.mint(ALICE, amt);
        usdc.approve(address(market), type(uint256).max);
        vm.stopPrank();
        ghostDeposits += amt;
    }

    function movePrice(uint256 p) public {
        uint256 cur = feed.getRound(feed.latestRound()).price;
        // stay within band so rounds are usable; occasionally drift down to trigger liquidations
        p = bound(p, cur * 91 / 100, cur * 109 / 100);
        if (p == 0) p = 1;
        feed.post(p);
    }

    function liquidateViaAccount(uint256 seed) public {
        uint256 id = _pos(seed);
        if (id == 0) return;
        if (market.healthFactor(id) >= 1e18) return;
        sawUnhealthy++;
        uint256 roundId = feed.latestRound();

        TxView memory v = _canonical(id, roundId);
        env.set(v);
        env.resetApprovals(address(account));
        vm.prank(address(account));
        try account.verifyLiquidation() {
            uint256 before = market.liquidationCount(id);
            vm.prank(address(account));
            account.selfLiquidate(id, roundId);
            if (market.liquidationCount(id) > before) successfulSteps++;
        } catch {
            verifyReverted++;
        }
    }

    /// Realistic scenario action: drive one position toward liquidation by posting an in-band down
    /// round, then liquidate it via the account. Ensures the conservation invariants are checked
    /// across real liquidation state transitions (the pure random walk rarely clusters enough drops).
    function crashAndLiquidate(uint256 seed, uint256 dropBps) public {
        if (posIds.length == 0) openAndFund(100e18, type(uint256).max); // ensure a position exists
        uint256 id = _pos(seed);
        if (id == 0) return;
        dropBps = bound(dropBps, 100, 900); // 1%..9% per round, stays in band (no breaker trip)
        // Gradual in-band crash: post down-rounds until the position is unhealthy or we hit a cap.
        for (uint256 k; k < 40 && market.healthFactor(id) >= 1e18; ++k) {
            uint256 cur = feed.getRound(feed.latestRound()).price;
            uint256 next = cur * (10_000 - dropBps) / 10_000;
            if (next == 0) next = 1;
            feed.post(next);
            if (cur == 1) break; // price floored; can't drop further
        }
        if (market.healthFactor(id) >= 1e18) return;
        sawUnhealthy++;
        uint256 roundId = feed.latestRound();
        TxView memory v = _canonical(id, roundId);
        env.set(v);
        env.resetApprovals(address(account));
        uint256 before = market.liquidationCount(id);
        vm.prank(address(account));
        try account.verifyLiquidation() {
            vm.prank(address(account));
            account.selfLiquidate(id, roundId);
            if (market.liquidationCount(id) > before) successfulSteps++;
        } catch {
            verifyReverted++;
        }
    }

    /// A stranger must never be able to call the account's execute() and bill the tank (C1).
    function strangerExecutes(uint256 seed, uint256 roundId) public {
        uint256 id = _pos(seed);
        if (id == 0) return;
        uint256 before = market.totalFeeBilled();
        try account.selfLiquidate(id, roundId) {} catch {}
        if (market.totalFeeBilled() > before) strangerExecuteBilled += 1;
    }

    /// A stranger must never be able to liquidate directly.
    function strangerLiquidates(uint256 seed, uint256 roundId) public {
        uint256 id = _pos(seed);
        if (id == 0) return;
        vm.prank(STRANGER);
        try market.executeLiquidation(id, roundId, 0.01e18) {
        // Should be impossible.
        }
        catch {
            strangerLiquidationReverts++;
        }
    }

    function _canonical(uint256 id, uint256 roundId) internal view returns (TxView memory v) {
        v.sender = address(account);
        v.nonceKeys = new uint256[](1);
        v.nonceKeys[0] = FirewallRules.nonceKey(address(market), id);
        v.sequence = market.liquidationCount(id);
        v.feeParam = account.feeCapTotal();
        v.frames = new FrameView[](2);
        v.frames[0] = FrameView(
            FrameTypes.MODE_VERIFY,
            address(account),
            200_000,
            ProbeConstants.FIRST_USE_KEY_STATE_GAS + 50_000,
            0,
            FrameTypes.SCOPE_EXECUTION_AND_PAYMENT,
            abi.encodeWithSelector(FirewallRules.VERIFY_SEL)
        );
        v.frames[1] = FrameView(
            FrameTypes.MODE_SENDER,
            address(account),
            300_000,
            0,
            0,
            FrameTypes.SCOPE_NONE,
            abi.encodeWithSelector(FirewallRules.EXECUTE_SEL, id, roundId)
        );
    }

    function posCount() external view returns (uint256) {
        return posIds.length;
    }

    function posAt(uint256 i) external view returns (uint256) {
        return posIds[i];
    }
}
