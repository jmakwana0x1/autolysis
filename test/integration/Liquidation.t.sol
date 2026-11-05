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
import {MockCurve} from "../mocks/MockCurve.sol";
import {MockFrameEnv} from "../mocks/MockFrameEnv.sol";

/// @notice Phase 1 exit: a first self-paid liquidation through the plain curve, driven the way the
///         devnet runs it — the carrier builds the canonical frame tx, VERIFY approves, SENDER executes.
contract LiquidationTest is Test {
    MockERC20 col;
    MockERC20 usdc;
    RoundFeed feed;
    MockFrameEnv env;
    AutolysisMarket market;
    AutolysisAccount account;
    MockCurve curve;

    address borrower = address(0xB0B);
    uint256 posId;

    function setUp() public {
        col = new MockERC20("Collateral", "COL", 18);
        usdc = new MockERC20("USD Coin", "USDC", 18);
        feed = new RoundFeed(address(this), 2e18); // 1 COL = 2 USDC

        env = new MockFrameEnv();
        account = new AutolysisAccount(env);
        market = new AutolysisMarket(
            IERC20(address(col)), IERC20(address(usdc)), IRoundFeed(address(feed)), address(account)
        );
        account.initialize(market, 0.01e18);
        curve = new MockCurve(IERC20(address(col)), IERC20(address(usdc)), IRoundFeed(address(feed)));
        market.setVenue(ISwapVenue(address(curve)));

        // Fund the market with USDC to lend, and the curve with USDC to buy collateral.
        usdc.mint(address(market), 1_000_000e18);
        usdc.mint(address(curve), 1_000_000e18);

        // Borrower opens, deposits 100 COL (=200 USDC), borrows 150 USDC. HF = 100*2*0.9/150 = 1.2.
        vm.startPrank(borrower);
        posId = market.open();
        col.mint(borrower, 100e18);
        col.approve(address(market), type(uint256).max);
        market.deposit(posId, 100e18);
        market.borrow(posId, 150e18);
        // Fund the gas tank.
        usdc.mint(borrower, 1e18);
        usdc.approve(address(market), type(uint256).max);
        market.refillTank(posId, 1e18);
        vm.stopPrank();

        assertGe(market.healthFactor(posId), 1e18, "should start healthy");
    }

    function _canonicalTx(uint256 roundId) internal view returns (TxView memory v) {
        v.sender = address(account);
        v.nonceKeys = new uint256[](1);
        v.nonceKeys[0] = FirewallRules.nonceKey(address(market), posId);
        v.sequence = market.liquidationCount(posId);
        v.feeParam = account.feeCapTotal();
        v.frames = new FrameView[](2);
        v.frames[0] = FrameView({
            mode: FrameTypes.MODE_VERIFY,
            target: address(account),
            gasLimit: 200_000,
            stateLimit: ProbeConstants.FIRST_USE_KEY_STATE_GAS + 50_000,
            value: 0,
            allowedScope: FrameTypes.SCOPE_EXECUTION_AND_PAYMENT,
            data: abi.encodeWithSelector(FirewallRules.VERIFY_SEL)
        });
        v.frames[1] = FrameView({
            mode: FrameTypes.MODE_SENDER,
            target: address(account),
            gasLimit: 300_000,
            stateLimit: 0,
            value: 0,
            allowedScope: FrameTypes.SCOPE_NONE,
            data: abi.encodeWithSelector(FirewallRules.EXECUTE_SEL, posId, roundId)
        });
    }

    /// Drive a frame tx the way the devnet would: load context, run VERIFY, then run SENDER-execute.
    function _runLiquidation(uint256 roundId) internal {
        TxView memory v = _canonicalTx(roundId);
        env.set(v);
        // VERIFY frame: called by the account itself via a delegatecall shim? Here the account reads env.
        vm.prank(address(account));
        account.verify();
        assertTrue(env.isApproved(address(account)), "VERIFY did not approve");
        // SENDER frame executes.
        vm.prank(address(account));
        account.execute(posId, roundId);
    }

    function test_firstSelfPaidLiquidation() public {
        // Gradual crash within the 10% band (a >10% spike would trip the breaker; that is a Phase 2
        // scene). 2.0 -> 1.8 -> 1.62: HF = 100*1.62*0.9/150 = 0.972 < 1 -> liquidatable.
        feed.post(1.8e18);
        feed.post(1.62e18);
        uint256 roundId = feed.latestRound();

        uint256 hfBefore = market.healthFactor(posId);
        assertLt(hfBefore, 1e18, "should be unhealthy after crash");

        uint256 seqBefore = market.liquidationCount(posId);
        _runLiquidation(roundId);

        uint256 hfAfter = market.healthFactor(posId);
        assertGe(hfAfter, hfBefore, "HF must not fall");
        assertEq(market.liquidationCount(posId), seqBefore + 1, "one step recorded");

        // Tank was billed exactly once, within the cap; conservation holds.
        (, uint256 colAmt, uint256 debtAmt,) = market.positions(posId);
        assertLt(debtAmt, 150e18, "debt reduced");
        assertLt(colAmt, 100e18, "collateral sold");
    }

    function test_envelopeDoesNotRevertOnBadVenue() public {
        feed.post(1.8e18);
        feed.post(1.62e18);
        uint256 roundId = feed.latestRound();
        // Drain the curve so the swap reverts (slippage): the envelope must still return cleanly.
        uint256 bal = usdc.balanceOf(address(curve));
        vm.prank(address(curve));
        usdc.transfer(address(0xdead), bal);

        TxView memory v = _canonicalTx(roundId);
        env.set(v);
        vm.prank(address(account));
        account.verify();
        vm.prank(address(account));
        account.execute(posId, roundId); // must not revert
        // Position unchanged (failed attempt), but a fee was billed.
        (,, uint256 debtAmt,) = market.positions(posId);
        assertEq(debtAmt, 150e18, "debt unchanged on failed attempt");
    }
}
