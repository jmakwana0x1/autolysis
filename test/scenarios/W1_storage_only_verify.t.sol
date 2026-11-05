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

/// W1.5: the storage-only VERIFY fallback. With `storageOnlyVerify` on, VERIFY takes the round/health
/// gate from a snapshot in the account's OWN storage (pushed in a prior non-VERIFY tx) instead of
/// calling the market. VERIFY then touches no outside contract, so it needs no ERC-8421 STORAGE-032
/// staked read. The gates are identical to the staked path.
contract W1StorageOnlyVerifyTest is Test {
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
        account.setStorageOnlyVerify(true);
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

    function _crash() internal returns (uint256) {
        feed.post(1.8e18);
        feed.post(1.62e18);
        return feed.latestRound();
    }

    function _runVerify(uint256 roundId) internal returns (bool ok) {
        env.resetApprovals(address(account));
        env.set(_tx(roundId, env.sequenceOf(FirewallRules.nonceKey(address(market), posId))));
        vm.prank(address(account));
        (ok,) = address(account).call(abi.encodeWithSelector(AutolysisAccount.verifyLiquidation.selector));
    }

    function test_approvesFromSnapshot() public {
        uint256 roundId = _crash();
        account.pushVerifySnapshot(posId, roundId); // reads the live market, outside VERIFY
        assertTrue(_runVerify(roundId), "storage-only VERIFY should approve a valid snapshot");
        assertTrue(env.isApproved(address(account)), "approved");
    }

    /// The clincher: with the snapshot already stored, make every market read REVERT. Staked VERIFY
    /// would blow up calling the market; storage-only VERIFY never calls it, so it still approves.
    function test_verifyReadsNoOutsideContract() public {
        uint256 roundId = _crash();
        account.pushVerifySnapshot(posId, roundId);

        // Any call into the market now reverts. VERIFY must not touch it.
        vm.mockCallRevert(address(market), bytes(""), "MARKET_READ_FORBIDDEN");

        assertTrue(_runVerify(roundId), "VERIFY must approve without reading the market");
        assertTrue(env.isApproved(address(account)), "approved from own storage only");

        // And proof the mock bites: a direct market read reverts.
        vm.expectRevert(bytes("MARKET_READ_FORBIDDEN"));
        market.healthFactor(posId);
    }

    function test_missingSnapshotRejected() public {
        uint256 roundId = _crash();
        assertFalse(_runVerify(roundId), "no snapshot -> reject");
        assertFalse(env.isApproved(address(account)), "not approved");
    }

    function test_wrongRoundSnapshotRejected() public {
        uint256 roundId = _crash();
        account.pushVerifySnapshot(posId, roundId);
        assertFalse(_runVerify(roundId + 1), "snapshot round mismatch -> reject");
        assertFalse(env.isApproved(address(account)), "not approved");
    }

    function test_healthySnapshotRejected() public {
        // Snapshot taken while the position is still healthy (price unchanged at 2.0) must not approve.
        feed.post(1.95e18); // HF still > 1
        uint256 roundId = feed.latestRound();
        account.pushVerifySnapshot(posId, roundId);
        assertFalse(_runVerify(roundId), "healthy snapshot -> reject");
        assertFalse(env.isApproved(address(account)), "not approved");
    }

    /// Stale snapshot: the round was already used (lastAttemptRound >= roundId) -> reject.
    function test_alreadyUsedRoundSnapshotRejected() public {
        uint256 roundId = _crash();
        // First liquidation (staked-style gate not needed; use the snapshot) uses the round.
        account.pushVerifySnapshot(posId, roundId);
        assertTrue(_runVerify(roundId), "first use approves");
        vm.prank(address(account));
        account.selfLiquidate(posId, roundId);
        assertEq(market.lastLiquidatedRound(posId), roundId, "round marked used");

        // Re-snapshot the same round: lastAttemptRound now == roundId, so the round gate rejects.
        if (market.healthFactor(posId) < 1e18) {
            account.pushVerifySnapshot(posId, roundId);
            assertFalse(_runVerify(roundId), "re-citing a used round -> reject");
        }
    }
}
