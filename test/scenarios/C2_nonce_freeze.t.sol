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

/// C2: a failed attempt burns the keyed nonce but not the liquidation count. The next attempt, using
/// the next sequence, must still approve and liquidate — the firewall must not tie sequence to the
/// liquidation count.
contract C2NonceFreezeTest is Test {
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
        market = new AutolysisMarket(IERC20(address(col)), IERC20(address(usdc)), IRoundFeed(address(feed)), address(account));
        account.initialize(market, 0.01e18);
        curve = new MockCurve(IERC20(address(col)), IERC20(address(usdc)), IRoundFeed(address(feed)));
        market.setVenue(ISwapVenue(address(curve)));
        usdc.mint(address(market), 1e24);
        usdc.mint(address(curve), 1e24);

        posId = market.open();
        col.mint(address(this), 100e18);
        col.approve(address(market), type(uint256).max);
        market.deposit(posId, 100e18);
        market.borrow(posId, 150e18);
        usdc.mint(address(this), 1e18);
        usdc.approve(address(market), type(uint256).max);
        market.refillTank(posId, 1e18);

        feed.post(1.8e18);
        feed.post(1.62e18); // HF 0.972 -> liquidatable, round 3 latest
    }

    function _tx(uint256 roundId, uint256 sequence) internal view returns (TxView memory v) {
        v.sender = address(account);
        v.nonceKeys = new uint256[](1);
        v.nonceKeys[0] = FirewallRules.nonceKey(address(market), posId);
        v.sequence = sequence;
        v.feeParam = account.feeCapTotal();
        v.expiry = block.timestamp + 100;
        v.frames = new FrameView[](2);
        v.frames[0] = FrameView(FrameTypes.MODE_VERIFY, address(account), 200_000, ProbeConstants.FIRST_USE_KEY_STATE_GAS + 50_000, 0, abi.encodeWithSelector(FirewallRules.VERIFY_SEL));
        v.frames[1] = FrameView(FrameTypes.MODE_SENDER, address(account), 300_000, 0, 0, abi.encodeWithSelector(FirewallRules.EXECUTE_SEL, posId, roundId));
    }

    function test_failedAttemptDoesNotFreezePosition() public {
        uint256 key = FirewallRules.nonceKey(address(market), posId);
        uint256 good = feed.latestRound();

        // Attempt #1 at sequence 0 but citing a bad (future/nonexistent) round: VERIFY approves the
        // shape, the nonce is burned (seq 0 -> 1), execution fails and bills a failed attempt.
        env.set(_tx(999, 0));
        vm.prank(address(account));
        account.verify();
        assertEq(env.sequenceOf(key), 1, "nonce should be burned at approve");
        vm.prank(address(account));
        account.execute(posId, 999); // fails inside the envelope, no liquidation
        assertEq(market.liquidationCount(posId), 0, "no successful step yet");

        // Attempt #2 must use the next sequence (1). It must still approve and liquidate.
        env.resetApprovals(address(account));
        env.set(_tx(good, 1));
        vm.prank(address(account));
        account.verify(); // with the sequence-rule bug this reverts (1 != liquidationCount 0)
        assertTrue(env.isApproved(address(account)), "next attempt must approve after a failed one");
        vm.prank(address(account));
        account.execute(posId, good);
        assertEq(market.liquidationCount(posId), 1, "the next attempt must liquidate");
    }
}
