// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TankLedger} from "../../src/libraries/TankLedger.sol";

contract TankLedgerHarness {
    using TankLedger for TankLedger.Tank;

    TankLedger.Tank internal t;

    function refill(uint256 a) external {
        t.refill(a);
    }

    function reserve(uint256 cap) external {
        t.reserve(cap);
    }

    function settle(uint256 actual) external {
        t.settle(actual);
    }

    function headroom(uint256 cap) external view returns (uint256) {
        return t.headroom(cap);
    }

    function drift() external view returns (int256) {
        return t.drift();
    }

    function state() external view returns (TankLedger.Tank memory) {
        return t;
    }
}

contract TankLedgerTest is Test {
    TankLedgerHarness h;
    uint256 constant CAP = 0.01e18;

    function setUp() public {
        h = new TankLedgerHarness();
    }

    function test_conservationAfterManyOps() public {
        h.refill(1e18);
        for (uint256 i; i < 50; ++i) {
            h.reserve(CAP);
            h.settle(CAP / 2); // bill half the cap each time
        }
        assertEq(h.drift(), 0, "deposited == balance + billed");
    }

    function test_reserveRespectsHeadroom() public {
        h.refill(CAP * 3);
        h.reserve(CAP);
        h.reserve(CAP);
        h.reserve(CAP);
        vm.expectRevert(TankLedger.InsufficientTank.selector);
        h.reserve(CAP); // 4th exceeds the tank
    }

    function testFuzz_driftAlwaysZero(uint8 n, uint256 seed) public {
        h.refill(10e18);
        n = uint8(bound(n, 1, 100));
        for (uint256 i; i < n; ++i) {
            if (h.headroom(CAP) == 0) break;
            h.reserve(CAP);
            uint256 bill = bound(uint256(keccak256(abi.encode(seed, i))), 0, CAP);
            h.settle(bill);
        }
        assertEq(h.drift(), 0);
    }
}
