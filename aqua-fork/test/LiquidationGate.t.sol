// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Context, SwapQuery, VM, SwapRegisters, ProtocolFee} from "@1inch/swap-vm/contracts/libs/VM.sol";
import {AutolysisAquaRouterGated} from "../src/AutolysisAquaRouterGated.sol";

/// Harness exposing the internal _dispatch so the LiquidationGate opcode can be exercised directly.
contract Harness is AutolysisAquaRouterGated {
    constructor(address aqua, address weth, address owner, address hook, address venue)
        AutolysisAquaRouterGated(aqua, weth, owner, "Autolysis", "1", hook, venue) {}

    /// Calls the real forked _dispatch with the LiquidationGate opcode (0xf9) and an empty program arg.
    function runGate(address taker, bytes calldata args) external {
        Context memory ctx;
        ctx.query.taker = taker;
        _dispatch(ctx, 0xf9, args);
    }
}

contract MockVenue {
    bool public liquidationActive;
    function set(bool v) external {
        liquidationActive = v;
    }
}

contract LiquidationGateTest is Test {
    Harness router;
    MockVenue venue;
    address hook = address(0xC0FFEE);

    function setUp() public {
        venue = new MockVenue();
        router = new Harness(address(0xA00A), address(0x9E79), address(this), hook, address(venue));
    }

    function test_gatePassesForHookWhenActive() public {
        venue.set(true);
        router.runGate(hook, ""); // must not revert
    }

    function test_gateRevertsForStranger() public {
        venue.set(true);
        vm.expectRevert(AutolysisAquaRouterGated.LiquidationGateClosed.selector);
        router.runGate(address(0xBAD), "");
    }

    function test_gateRevertsWhenInactive() public {
        venue.set(false);
        vm.expectRevert(AutolysisAquaRouterGated.LiquidationGateClosed.selector);
        router.runGate(hook, "");
    }
}
