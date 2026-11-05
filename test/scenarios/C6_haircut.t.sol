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

/// C6: with a real venue haircut, liquidations must still succeed (minOut is the haircut floor, not
/// the raw debt). The step prices against s = 1%, so any haircut in [0, 1%] must clear.
contract C6HaircutTest is Test {
    MockFrameEnv env;
    AutolysisMarket market;
    AutolysisAccount account;
    MockCurve curve;
    RoundFeed feed;
    MockERC20 col;
    MockERC20 usdc;
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
        usdc.mint(address(market), 1e24);
        usdc.mint(address(curve), 1e24);

        posId = market.open();
        col.mint(address(this), 100e18);
        col.approve(address(market), type(uint256).max);
        market.deposit(posId, 100e18);
        market.borrow(posId, 150e18); // HF = 100*2*0.8/150 = 1.0667
        usdc.mint(address(this), 10e18);
        usdc.approve(address(market), type(uint256).max);
        market.refillTank(posId, 10e18);
    }

    function _tx(uint256 roundId, uint256 seq) internal view returns (TxView memory v) {
        v.sender = address(account);
        v.nonceKeys = new uint256[](1);
        v.nonceKeys[0] = FirewallRules.nonceKey(address(market), posId);
        v.sequence = seq;
        v.feeParam = account.feeCapTotal();
        v.expiry = block.timestamp + 100;
        v.frames = new FrameView[](2);
        v.frames[0] = FrameView(
            FrameTypes.MODE_VERIFY,
            address(account),
            200_000,
            ProbeConstants.FIRST_USE_KEY_STATE_GAS + 50_000,
            0,
            abi.encodeWithSelector(FirewallRules.VERIFY_SEL)
        );
        v.frames[1] = FrameView(
            FrameTypes.MODE_SENDER,
            address(account),
            300_000,
            0,
            0,
            abi.encodeWithSelector(FirewallRules.EXECUTE_SEL, posId, roundId)
        );
    }

    function _liquidate(uint256 roundId, uint256 seq) internal returns (bool stepped) {
        env.resetApprovals(address(account));
        env.set(_tx(roundId, seq));
        vm.prank(address(account));
        account.verify();
        uint256 before = market.liquidationCount(posId);
        vm.prank(address(account));
        account.execute(posId, roundId);
        stepped = market.liquidationCount(posId) > before;
    }

    function _crash() internal returns (uint256) {
        feed.post(1.8e18);
        feed.post(1.62e18); // HF ~0.864 at L=0.8
        return feed.latestRound();
    }

    function _run(uint256 haircutBps) internal {
        curve.setHaircut(haircutBps);
        uint256 roundId = _crash();
        assertLt(market.healthFactor(posId), 1e18, "should be unhealthy");
        uint256 seq = 0;
        bool anyStep;
        for (uint256 i; i < 6 && market.healthFactor(posId) < 1e18; ++i) {
            if (_liquidate(roundId, seq)) anyStep = true;
            seq = env.sequenceOf(FirewallRules.nonceKey(address(market), posId));
        }
        assertTrue(anyStep, "no liquidation stepped under haircut");
        assertGe(market.healthFactor(posId), 1e18, "should be healthy after liquidation");
    }

    function test_haircut50bps() public {
        _run(50);
    }

    function test_haircut100bps() public {
        _run(100);
    }

    function testFuzz_haircutWithinSlippage(uint256 bps) public {
        bps = bound(bps, 0, 100); // s = 1%
        _run(bps);
    }
}
