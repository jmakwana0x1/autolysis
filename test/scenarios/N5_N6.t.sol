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

contract N5N6Test is Test {
    MockFrameEnv env;
    AutolysisMarket market;
    AutolysisAccount account;
    MockCurve curve;
    RoundFeed feed;
    MockWETH col;
    MockERC20 usdc;
    address borrower = address(0xB0B);
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

        vm.startPrank(borrower);
        posId = market.open();
        col.mint(borrower, 100e18);
        col.approve(address(market), type(uint256).max);
        market.deposit(posId, 100e18);
        market.borrow(posId, 150e18);
        vm.stopPrank();

        feed.post(1.8e18);
        feed.post(1.62e18); // HF ~0.864 -> liquidatable
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

    function _verifyOk(uint256 roundId, uint256 seq) internal returns (bool) {
        env.resetApprovals(address(account));
        env.set(_tx(roundId, seq));
        vm.prank(address(account));
        (bool ok,) = address(account).call(abi.encodeWithSelector(AutolysisAccount.verifyLiquidation.selector));
        return ok && env.isApproved(address(account));
    }

    // N5: a failed attempt at round r blocks another attempt at round r; r+1 is allowed.
    function test_failedAttemptBlocksSameRoundRetry() public {
        uint256 r = feed.latestRound();
        // Drain the venue so the attempt fails.
        uint256 bal = usdc.balanceOf(address(curve));
        vm.prank(address(curve));
        usdc.transfer(address(0xdead), bal);

        assertTrue(_verifyOk(r, 0), "first attempt at r should approve");
        vm.prank(address(account));
        account.selfLiquidate(posId, r); // fails, bills, records lastAttemptRound = r
        assertEq(market.lastAttemptRound(posId), r, "attempt round recorded on failure");

        // A second attempt at the SAME round r must be rejected in VERIFY.
        assertFalse(_verifyOk(r, 1), "same round must not be retried after a failed attempt");

        // A fresh round r+1 is allowed again.
        feed.post(1.6e18);
        assertTrue(_verifyOk(feed.latestRound(), 1), "a new round must be allowed");
    }

    // N6: the never-revert envelope does not depend on load() (FRAMEPARAM/FRAMEDATALOAD). Even if load()
    // reverts, selfLiquidate runs via maxCost() and bills the failed attempt.
    function test_envelopeRunsEvenIfLoadReverts() public {
        uint256 r = feed.latestRound();
        uint256 bal = usdc.balanceOf(address(curve));
        vm.prank(address(curve));
        usdc.transfer(address(0xdead), bal); // make the liquidation fail inside the envelope

        env.set(_tx(r, 0));
        env.setFailLoad(true); // load() now reverts; maxCost() still works
        uint256 billedBefore = market.totalFeeBilled();
        vm.prank(address(account));
        account.selfLiquidate(posId, r); // must not revert
        assertGt(market.totalFeeBilled(), billedBefore, "failed attempt billed via maxCost(), not load()");
    }
}
