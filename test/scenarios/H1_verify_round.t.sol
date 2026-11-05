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

/// H1: VERIFY must reject a bad round (too old / future / out of band / breaker pending / already used)
/// rather than approve it and let execution fail and bill the borrower.
contract H1VerifyRoundTest is Test {
    MockFrameEnv env;
    AutolysisMarket market;
    AutolysisAccount account;
    MockCurve curve;
    RoundFeed feed;
    MockWETH col;
    MockERC20 usdc;
    uint256 posId;

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

        posId = market.open();
        col.mint(address(this), 100e18);
        col.approve(address(market), type(uint256).max);
        market.deposit(posId, 100e18);
        market.borrow(posId, 150e18); // HF ~1.0667 at price 2, L=0.8
        usdc.mint(address(this), 10e18);
        usdc.approve(address(market), type(uint256).max);
    }

    function _tx(uint256 roundId, uint256 seq) internal view returns (TxView memory v) {
        v.sender = address(account);
        v.nonceKeys = new uint256[](1);
        v.nonceKeys[0] = FirewallRules.nonceKey(address(market), posId);
        v.sequence = seq;
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
            abi.encodeWithSelector(FirewallRules.EXECUTE_SEL, posId, roundId)
        );
    }

    function _verifyReverts(uint256 roundId) internal {
        env.resetApprovals(address(account));
        env.set(_tx(roundId, env.sequenceOf(FirewallRules.nonceKey(address(market), posId))));
        vm.prank(address(account));
        (bool ok,) = address(account).call(abi.encodeWithSelector(AutolysisAccount.verifyLiquidation.selector));
        assertFalse(ok, "VERIFY should have rejected the bad round");
        assertFalse(env.isApproved(address(account)), "must not approve a bad round");
    }

    // Gradual in-band crash to make the position liquidatable; returns the latest round.
    function _crash() internal returns (uint256) {
        feed.post(1.8e18);
        feed.post(1.62e18);
        return feed.latestRound();
    }

    function test_futureRoundRejected() public {
        _crash();
        _verifyReverts(999); // > latest
    }

    function test_staleRoundRejected() public {
        _crash();
        // push several more in-band rounds so the crash round falls outside the K-window
        feed.post(1.5e18);
        feed.post(1.4e18);
        feed.post(1.33e18);
        feed.post(1.26e18);
        _verifyReverts(3); // the 1.62 crash round, now > K rounds old
    }

    function test_breakerPendingRoundRejected() public {
        feed.post(1.4e18); // -30% from 2.0: breaker trips on this round, unconfirmed
        _verifyReverts(feed.latestRound());
    }

    function test_healthyRoundRejected() public {
        // a fresh round where the position is still healthy must not approve
        feed.post(1.95e18); // HF still > 1
        _verifyReverts(feed.latestRound());
    }

    function test_alreadyUsedRoundRejected() public {
        uint256 roundId = _crash();
        // one successful liquidation sets lastLiquidatedRound = roundId
        env.resetApprovals(address(account));
        env.set(_tx(roundId, 0));
        vm.prank(address(account));
        account.verifyLiquidation();
        vm.prank(address(account));
        account.selfLiquidate(posId, roundId);
        assertEq(market.lastLiquidatedRound(posId), roundId);
        // if still unhealthy, re-citing the same (now used) round must reject
        if (market.healthFactor(posId) < 1e18) _verifyReverts(roundId);
    }

    function test_goodRoundApproves() public {
        uint256 roundId = _crash();
        env.resetApprovals(address(account));
        env.set(_tx(roundId, 0));
        vm.prank(address(account));
        account.verifyLiquidation();
        assertTrue(env.isApproved(address(account)), "a good, in-window, unhealthy round must approve");
    }
}
