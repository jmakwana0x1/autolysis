// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AutolysisMarket} from "../../src/core/AutolysisMarket.sol";
import {AutolysisAccount} from "../../src/core/AutolysisAccount.sol";
import {RoundFeed} from "../../src/core/RoundFeed.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {IRoundFeed} from "../../src/interfaces/IRoundFeed.sol";
import {ISwapVenue} from "../../src/interfaces/ISwapVenue.sol";
import {TankLedger} from "../../src/libraries/TankLedger.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockCurve} from "../mocks/MockCurve.sol";
import {MockFrameEnv} from "../mocks/MockFrameEnv.sol";
import {MarketHandler} from "./MarketHandler.sol";

/// @notice Stateful market invariants (Phase 1-2). The handler drives random sequences; after every
///         call these must hold.
contract MarketInvariantTest is Test {
    AutolysisMarket market;
    AutolysisAccount account;
    RoundFeed feed;
    MockFrameEnv env;
    MockERC20 col;
    MockERC20 usdc;
    MockCurve curve;
    MarketHandler handler;

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

        handler = new MarketHandler(market, account, feed, env, col, usdc);
        feed.transferUpdater(address(handler)); // handler drives price updates
        targetContract(address(handler));

        bytes4[] memory sel = new bytes4[](9);
        sel[0] = handler.openAndFund.selector;
        sel[1] = handler.deposit.selector;
        sel[2] = handler.repay.selector;
        sel[3] = handler.refillTank.selector;
        sel[4] = handler.movePrice.selector;
        sel[5] = handler.liquidateViaAccount.selector;
        sel[6] = handler.strangerLiquidates.selector;
        sel[7] = handler.crashAndLiquidate.selector;
        sel[8] = handler.strangerExecutes.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    /// Total collateral held by the market equals the sum of position collateral plus sold-out amounts.
    function invariant_collateralConserved() public view {
        uint256 sumCol;
        uint256 n = handler.posCount();
        for (uint256 i; i < n; ++i) {
            (, uint256 c,,) = market.positions(handler.posAt(i));
            sumCol += c;
        }
        assertEq(market.totalCollateral(), sumCol, "totalCollateral != sum positions");
        // Physical collateral token held equals current position collateral (sold-out left the market).
        assertEq(col.balanceOf(address(market)), market.totalCollateral(), "collateral token mismatch");
    }

    /// Total debt equals the sum of position debts.
    function invariant_debtConserved() public view {
        uint256 sumDebt;
        uint256 n = handler.posCount();
        for (uint256 i; i < n; ++i) {
            (,, uint256 d,) = market.positions(handler.posAt(i));
            sumDebt += d;
        }
        assertEq(market.totalDebt(), sumDebt, "totalDebt != sum positions");
    }

    /// The "liquidation active" flag is never set outside a liquidation call.
    function invariant_activeFlagClear() public view {
        assertFalse(market.liquidationActive(), "active flag stuck");
    }

    uint256 internal lastSoldOut;

    /// C1: a stranger calling execute() never bills the tank.
    function invariant_strangerExecuteNeverBills() public view {
        assertEq(handler.strangerExecuteBilled(), 0, "stranger execute billed the tank");
    }


    /// Collateral only ever leaves a position through an accounted liquidation sale, so the market's
    /// sold-out total is monotonic non-decreasing. A stranger-driven sale would be unaccounted; the
    /// stranger path is also asserted to always revert in afterInvariant.
    function invariant_soldOutMonotonic() public {
        uint256 cur = market.totalSoldOut();
        assertGe(cur, lastSoldOut, "totalSoldOut decreased");
        lastSoldOut = cur;
    }

    /// Tank conservation: for every position, deposited == balance + billed (drift zero).
    function invariant_tankDriftZero() public view {
        uint256 n = handler.posCount();
        for (uint256 i; i < n; ++i) {
            TankLedger.Tank memory t = market.tank(handler.posAt(i));
            assertEq(
                int256(uint256(t.deposited)) - int256(uint256(t.balance)) - int256(uint256(t.billed)), 0, "tank drift"
            );
        }
    }

    function afterInvariant() public {
        // Coverage sanity: over a full run the handler must drive at least one successful account
        // liquidation and exercise the stranger-liquidation path (which must always revert).
        emit log_named_uint("sawUnhealthy", handler.sawUnhealthy());
        emit log_named_uint("verifyReverted", handler.verifyReverted());
        emit log_named_uint("successfulSteps", handler.successfulSteps());
        assertGt(handler.successfulSteps(), 0, "no liquidations exercised");
        assertGt(handler.strangerLiquidationReverts(), 0, "stranger liquidation path not exercised");
    }
}
