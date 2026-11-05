// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AutolysisMarket} from "../../src/core/AutolysisMarket.sol";
import {AutolysisAccount} from "../../src/core/AutolysisAccount.sol";
import {RoundFeed} from "../../src/core/RoundFeed.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {IRoundFeed} from "../../src/interfaces/IRoundFeed.sol";
import {ISwapVenue} from "../../src/interfaces/ISwapVenue.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockCurve} from "../mocks/MockCurve.sol";
import {MockFrameEnv} from "../mocks/MockFrameEnv.sol";

/// C1: a stranger must not be able to call execute() and bill the borrower's tank.
contract C1ExecuteGuardTest is Test {
    AutolysisMarket market;
    AutolysisAccount account;
    RoundFeed feed;
    MockERC20 col;
    MockERC20 usdc;
    uint256 posId;

    function setUp() public {
        col = new MockERC20("COL", "COL", 18);
        usdc = new MockERC20("USDC", "USDC", 18);
        feed = new RoundFeed(address(this), 2e18);
        MockFrameEnv env = new MockFrameEnv();
        account = new AutolysisAccount(env);
        market = new AutolysisMarket(
            IERC20(address(col)), IERC20(address(usdc)), IRoundFeed(address(feed)), address(account)
        );
        account.initialize(market, 0.01e18);
        MockCurve curve = new MockCurve(IERC20(address(col)), IERC20(address(usdc)), IRoundFeed(address(feed)));
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
    }

    function test_strangerCannotCallExecute() public {
        AutolysisMarket.Position memory before;
        (,, uint256 debtBefore,) = market.positions(posId);
        vm.prank(address(0xBAD));
        vm.expectRevert(AutolysisAccount.NotSelf.selector);
        account.execute(posId, 1);
        // tank must be untouched
        (,, uint256 debtAfter,) = market.positions(posId);
        assertEq(debtAfter, debtBefore);
        before;
    }
}
