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
import {TankLedger} from "../../src/libraries/TankLedger.sol";
import {TxView, FrameView, FrameTypes} from "../../src/frame/FrameTypes.sol";
import {ProbeConstants} from "../../src/generated/ProbeConstants.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockCurve} from "../mocks/MockCurve.sol";
import {MockFrameEnv} from "../mocks/MockFrameEnv.sol";

/// @notice Phase 2 adversarial scenarios, run against the real contracts with the frame-env mock
///         (every devnet scene has a matching mock test). Each asserts the expected outcome from the
///         plan's adversarial table.
contract AdversarialTest is Test {
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
        col = new MockERC20("COL", "COL", 18);
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
        usdc.mint(address(market), 1e30);
        usdc.mint(address(curve), 1e30);

        vm.startPrank(borrower);
        posId = market.open();
        col.mint(borrower, 100e18);
        col.approve(address(market), type(uint256).max);
        market.deposit(posId, 100e18);
        market.borrow(posId, 150e18); // HF 1.2 at price 2.0
        usdc.mint(borrower, 1e18);
        usdc.approve(address(market), type(uint256).max);
        market.refillTank(posId, 1e18);
        vm.stopPrank();
    }

    function _canonical(uint256 roundId) internal view returns (TxView memory v) {
        v.sender = address(account);
        v.nonceKeys = new uint256[](1);
        v.nonceKeys[0] = FirewallRules.nonceKey(address(market), posId);
        v.sequence = market.liquidationCount(posId);
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

    function _crashInBand() internal returns (uint256 roundId) {
        feed.post(1.8e18);
        feed.post(1.62e18); // HF 0.972
        roundId = feed.latestRound();
    }

    function _verify(TxView memory v) internal returns (bool ok) {
        env.set(v);
        env.resetApprovals(address(account));
        vm.prank(address(account));
        try account.verify() {
            ok = env.isApproved(address(account));
        } catch {
            ok = false;
        }
    }

    // Rescue in the same block: borrower repays, the pending liquidation becomes invalid (VERIFY rejects).
    function test_rescueInvalidatesPending() public {
        uint256 roundId = _crashInBand();
        assertTrue(_verify(_canonical(roundId)), "unhealthy: should approve before rescue");
        // Borrower rescues by repaying.
        vm.startPrank(borrower);
        usdc.mint(borrower, 60e18);
        usdc.approve(address(market), type(uint256).max);
        market.repay(posId, 60e18); // debt 90, HF = 100*1.62*0.9/90 = 1.62
        vm.stopPrank();
        assertGe(market.healthFactor(posId), 1e18, "healthy after rescue");
        assertFalse(_verify(_canonical(roundId)), "VERIFY must reject after rescue");
    }

    // Key-append rebroadcast: an attacker copies the tx and adds a key; VERIFY rejects.
    function test_keyAppendRejected() public {
        uint256 roundId = _crashInBand();
        TxView memory v = _canonical(roundId);
        uint256[] memory keys = new uint256[](2);
        keys[0] = v.nonceKeys[0];
        keys[1] = 0xdead;
        v.nonceKeys = keys;
        assertFalse(_verify(v), "key-append must be rejected");
    }

    // Rival with a fake round: a tx citing an out-of-band round is rejected (the feed refuses the price).
    function test_fakeRoundRejected() public {
        _crashInBand();
        // Push the latest far from round 2 so round 2 is out of band, then cite round 2.
        feed.post(1.5e18);
        feed.post(1.4e18);
        TxView memory v = _canonical(2); // cite the stale/out-of-band round
        // VERIFY passes the firewall shape (round matches the execute arg) but execute reverts in the
        // feed; the never-revert envelope bills a failed attempt and does not change the position.
        env.set(v);
        env.resetApprovals(address(account));
        vm.prank(address(account));
        // health at latest is unhealthy, so VERIFY approves the shape; the bad round bites at execute.
        try account.verify() {} catch {}
        (,, uint256 debtBefore,) = market.positions(posId);
        vm.prank(address(account));
        account.execute(posId, 2);
        (,, uint256 debtAfter,) = market.positions(posId);
        assertEq(debtAfter, debtBefore, "out-of-band round must not liquidate");
    }

    // Fee griefing: a tx with a fee above the cap is rejected; failed-attempt billing never exceeds cap.
    function test_feeGriefingRejected() public {
        uint256 roundId = _crashInBand();
        TxView memory v = _canonical(roundId);
        v.feeParam = account.feeCapTotal() + 1;
        assertFalse(_verify(v), "fee above cap must be rejected");
    }

    function test_failedAttemptBillingWithinCap() public {
        uint256 roundId = _crashInBand();
        // Drain curve so the swap fails -> failed attempt.
        uint256 bal = usdc.balanceOf(address(curve));
        vm.prank(address(curve));
        usdc.transfer(address(0xdead), bal);

        TankLedger.Tank memory before = market.tank(posId);
        TxView memory v = _canonical(roundId);
        env.set(v);
        vm.prank(address(account));
        account.verify();
        vm.prank(address(account));
        account.execute(posId, roundId);
        TankLedger.Tank memory afterT = market.tank(posId);
        uint256 billed = afterT.billed - before.billed;
        assertLe(billed, 0.01e18, "failed-attempt billing exceeded cap");
        assertGt(billed, 0, "a failed attempt should still bill");
    }

    // Gradual three-step sale: repeated steps reduce debt without the HF ever falling.
    function test_gradualThreeStepSale() public {
        uint256 roundId = _crashInBand();
        uint256 prevHf = market.healthFactor(posId);
        uint256 steps;
        for (uint256 i; i < 3; ++i) {
            if (market.healthFactor(posId) >= 1e18) break;
            TxView memory v = _canonical(roundId);
            env.set(v);
            env.resetApprovals(address(account));
            vm.prank(address(account));
            try account.verify() {
                uint256 before = market.liquidationCount(posId);
                vm.prank(address(account));
                account.execute(posId, roundId);
                if (market.liquidationCount(posId) > before) {
                    steps++;
                    uint256 hf = market.healthFactor(posId);
                    assertGe(hf, prevHf, "HF fell during gradual sale");
                    prevHf = hf;
                }
            } catch {}
        }
        assertGt(steps, 0, "no gradual steps executed");
    }
}
