// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AutolysisMarket} from "../../src/core/AutolysisMarket.sol";
import {AutolysisAccount} from "../../src/core/AutolysisAccount.sol";
import {RoundFeed} from "../../src/core/RoundFeed.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {IRoundFeed} from "../../src/interfaces/IRoundFeed.sol";
import {ISwapVenue} from "../../src/interfaces/ISwapVenue.sol";
import {FirewallRules} from "../../src/libraries/FirewallRules.sol";
import {TxView, FrameView, FrameTypes} from "../../src/frame/FrameTypes.sol";
import {ProbeConstants} from "../../src/generated/ProbeConstants.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MockCurve} from "../mocks/MockCurve.sol";
import {MockFrameEnv} from "../mocks/MockFrameEnv.sol";

/// D1 (PLAN-v4.4): the classic lender fallback. Below HF 0.95, after 3 consecutive unhealthy rounds with
/// no successful self-liquidation (and no change to the position), anyone may repay up to 50% of the
/// debt for collateral at a 5% bonus. The streak is counted on chain by `markUnhealthy`.
contract D1ClassicTest is Test {
    MockFrameEnv env;
    AutolysisMarket market;
    AutolysisAccount account;
    MockCurve curve;
    RoundFeed feed;
    MockWETH col;
    MockERC20 usdc;
    uint256 posId;
    address borrower = address(0xB0B);
    address lender = address(0x1E4D);

    function setUp() public {
        col = new MockWETH();
        vm.deal(address(col), 1_000 ether);
        usdc = new MockERC20("USDC", "USDC", 18);
        feed = new RoundFeed(address(this), 2e18);
        env = new MockFrameEnv();
        account = new AutolysisAccount(env);
        market = new AutolysisMarket(
            IERC20(address(col)), IERC20(address(usdc)), IRoundFeed(address(feed)), address(account)
        );
        account.initialize(market, 0.01e18);
        curve = new MockCurve(IERC20(address(col)), IERC20(address(usdc)), IRoundFeed(address(feed)));
        market.setVenue(ISwapVenue(address(curve)));
        usdc.mint(address(market), 1e24);
        usdc.mint(address(curve), 1e24);

        vm.startPrank(borrower);
        posId = market.open();
        col.mint(borrower, 100e18);
        col.approve(address(market), type(uint256).max);
        market.deposit(posId, 100e18);
        market.borrow(posId, 150e18); // HF 1.0667 at price 2
        usdc.mint(borrower, 100e18);
        usdc.approve(address(market), type(uint256).max);
        vm.stopPrank();

        usdc.mint(lender, 1e24);
        vm.prank(lender);
        usdc.approve(address(market), type(uint256).max);
    }

    function _postAndMark(uint256 price) internal returns (uint256 streak) {
        feed.post(price);
        streak = market.markUnhealthy(posId);
    }

    /// 1.8 (HF .96) -> 1.62 (HF .864) -> 1.62: three marked unhealthy rounds, HF < 0.95.
    function _openWindow() internal {
        assertEq(_postAndMark(1.8e18), 1);
        assertEq(_postAndMark(1.62e18), 2);
        assertFalse(market.classicOpen(posId), "closed after only 2 rounds");
        assertEq(_postAndMark(1.62e18), 3);
    }

    function _classic(uint256 amt) internal returns (uint256 repaid, uint256 out) {
        vm.prank(lender);
        return market.classicLiquidate(posId, amt);
    }

    function test_closedWhileHealthy() public {
        assertFalse(market.classicOpen(posId));
        vm.expectRevert(AutolysisMarket.Healthy.selector);
        market.markUnhealthy(posId);
        vm.prank(lender);
        vm.expectRevert(AutolysisMarket.ClassicClosed.selector);
        market.classicLiquidate(posId, 1e18);
    }

    function test_closedBeforeThreeRounds() public {
        _postAndMark(1.8e18);
        _postAndMark(1.62e18);
        vm.prank(lender);
        vm.expectRevert(AutolysisMarket.ClassicClosed.selector);
        market.classicLiquidate(posId, 1e18);
    }

    function test_closedAboveThresholdEvenAfterThreeRounds() public {
        // HF .96 for three rounds: unhealthy (self-liquidation's job) but not below 0.95.
        _postAndMark(1.8e18);
        _postAndMark(1.8e18);
        assertEq(_postAndMark(1.8e18), 3);
        assertFalse(market.classicOpen(posId), "HF 0.96 is not below the 0.95 threshold");
    }

    function test_opensAfterThreeRoundsAndPaysFivePercentBonus() public {
        _openWindow();
        assertTrue(market.classicOpen(posId));
        (,, uint256 debt0,) = market.positions(posId);
        uint256 col0 = col.balanceOf(lender);

        (uint256 repaid, uint256 out) = _classic(20e18);

        assertEq(repaid, 20e18);
        assertEq(out, uint256(20e18) * 10_500 * 1e18 / (1.62e18 * 10_000), "5% bonus at the latest price");
        assertEq(col.balanceOf(lender) - col0, out, "lender received the collateral");
        (,, uint256 debt1,) = market.positions(posId);
        assertEq(debt0 - debt1, repaid, "debt reduced by the repayment");
        assertEq(market.totalClassicOut(), out);
        assertFalse(market.classicOpen(posId), "a classic fill restarts the window");
        assertFalse(market.liquidationActive());
    }

    function test_closeFactorCapsAtHalfTheDebt() public {
        _openWindow();
        (,, uint256 debt0,) = market.positions(posId);
        (uint256 repaid,) = _classic(type(uint128).max);
        assertEq(repaid, debt0 / 2, "at most 50% of the debt per call");
    }

    function test_cappedAtCollateralWhenDeeplyUnderwater() public {
        // Walk the price down 10% per round (in band) until collateral * price * 1.05 < debt / 2.
        uint256 p = 2e18;
        for (uint256 i; i < 12; ++i) {
            p = p * 9 / 10;
            _postAndMark(p);
        }
        assertTrue(market.classicOpen(posId));
        (, uint256 c0,,) = market.positions(posId);
        (uint256 repaid, uint256 out) = _classic(type(uint128).max);
        assertEq(out, c0, "takes at most all the collateral");
        assertEq(repaid, out * p * 10_000 / (10_500 * 1e18), "repayment shrinks to match");
    }

    /// Found by invariant_noDanglingDebt: taking the last collateral must write the leftover debt off.
    function test_takingAllCollateralWritesOffTheRest() public {
        uint256 p = 2e18;
        for (uint256 i; i < 12; ++i) {
            p = p * 9 / 10;
            _postAndMark(p);
        }
        (,, uint256 d0,) = market.positions(posId);
        (uint256 repaid,) = _classic(type(uint128).max);
        (, uint256 c1, uint256 d1,) = market.positions(posId);
        assertEq(c1, 0, "all collateral taken");
        assertEq(d1, 0, "no debt left against zero collateral");
        assertEq(market.badDebt(), d0 - repaid, "shortfall written off");
    }

    function _selfLiquidate(uint256 roundId) internal {
        TxView memory v;
        v.sender = address(account);
        v.nonceKeys = new uint256[](1);
        v.nonceKeys[0] = FirewallRules.nonceKey(address(market), posId);
        v.feeParam = account.feeCapTotal();
        v.frames = new FrameView[](2);
        v.frames[0] = FrameView(FrameTypes.MODE_VERIFY, address(account), 99_900, ProbeConstants.FIRST_USE_KEY_STATE_GAS + 50_000, 0, FrameTypes.SCOPE_EXECUTION_AND_PAYMENT, abi.encodeWithSelector(FirewallRules.VERIFY_SEL));
        v.frames[1] = FrameView(FrameTypes.MODE_SENDER, address(account), 1_500_000, 0, 0, FrameTypes.SCOPE_NONE, abi.encodeWithSelector(FirewallRules.EXECUTE_SEL, posId, roundId));
        env.set(v);
        vm.prank(address(account));
        account.selfLiquidate(posId, roundId);
    }

    function test_successfulSelfLiquidationRestartsTheWindow() public {
        _postAndMark(1.8e18);
        _postAndMark(1.62e18);
        uint256 before = market.liquidationCount(posId);
        _selfLiquidate(feed.latestRound());
        assertEq(market.liquidationCount(posId), before + 1, "self-liquidation succeeded");
        (, uint128 streak) = market.classicWatch(posId);
        assertEq(streak, 0, "streak cleared by the self-liquidation");
    }

    function test_failedSelfLiquidationDoesNotHoldTheWindowShut() public {
        _postAndMark(1.8e18);
        _postAndMark(1.62e18);
        uint256 r = feed.latestRound();
        vm.prank(address(account));
        market.billFailedAttempt(posId, r, 0); // the carrier tried and failed
        assertEq(_postAndMark(1.62e18), 3, "a failed attempt keeps counting");
        assertTrue(market.classicOpen(posId));
    }

    function test_positionChangeRestartsTheWindow() public {
        _postAndMark(1.8e18);
        _postAndMark(1.62e18);
        vm.prank(borrower);
        market.repay(posId, 1e18);
        assertEq(_postAndMark(1.62e18), 1, "repay reset the streak");
    }

    function test_skippedRoundRestartsTheStreak() public {
        _postAndMark(1.8e18);
        _postAndMark(1.62e18);
        feed.post(1.62e18); // nobody marked this round
        assertEq(_postAndMark(1.62e18), 1, "a gap restarts the streak");
        assertEq(market.markUnhealthy(posId), 1, "a second mark in the same round does not extend it");
    }
}
