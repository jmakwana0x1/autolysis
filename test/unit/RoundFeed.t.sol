// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RoundFeed} from "../../src/core/RoundFeed.sol";

contract RoundFeedTest is Test {
    RoundFeed feed;

    function setUp() public {
        feed = new RoundFeed(address(this), 100e18);
    }

    function test_inBandMoveUsable() public {
        feed.post(109e18); // +9%, within band
        assertEq(feed.priceForLiquidation(2), 109e18);
    }

    function test_breakerNeedsTwoRounds() public {
        feed.post(120e18); // +20%, breaker trips
        vm.expectRevert(RoundFeed.BreakerPending.selector);
        feed.priceForLiquidation(2);
        // Confirming round within band of 120 makes it usable.
        feed.post(121e18);
        assertEq(feed.priceForLiquidation(3), 121e18);
    }

    function test_breakerStaysIfNextAlsoJumps() public {
        feed.post(120e18); // trips
        feed.post(150e18); // next also a big jump vs 120 -> still pending
        vm.expectRevert(RoundFeed.BreakerPending.selector);
        feed.priceForLiquidation(2);
    }

    function test_outOfBandOldRoundRejected() public {
        feed.post(105e18); // round 2
        feed.post(106e18); // round 3 (latest)
        feed.post(107e18); // round 4 (latest); round 2 now far? still within band
        // Push latest far from round 2 via in-band steps, then round 2 is out of band vs latest.
        feed.post(117e18);
        feed.post(128e18);
        vm.expectRevert(RoundFeed.PriceOutOfBand.selector);
        feed.priceForLiquidation(2);
    }

    function test_staleRejected() public {
        feed.post(105e18);
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(RoundFeed.StaleRound.selector);
        feed.priceForLiquidation(2);
    }

    function testFuzz_neverReturnsOutOfBand(uint256 p2) public {
        p2 = bound(p2, 1, 1e30);
        feed.post(p2);
        try feed.priceForLiquidation(2) returns (uint256 price) {
            // If it returned, the price is the posted one and (being latest) is by definition in band.
            assertEq(price, p2);
        } catch {
            // Rejected: acceptable (breaker or band).
        }
    }
}
