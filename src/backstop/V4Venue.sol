// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISwapVenue} from "../interfaces/ISwapVenue.sol";
import {IERC20Min} from "../interfaces/IERC20Min.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "v4-core-test/utils/CurrencySettler.sol";
import {BackstopHook} from "./BackstopHook.sol";

/// @title V4Venue
/// @notice The market's sale path through the Uniswap v4 pool + BackstopHook. It is the unlock caller,
///         so the hook sees `sender == this venue` and authorizes against `registeredVenue[venue]` and
///         `venue.liquidationActive()` — a liquidation cannot be forged by passing hookData (C3). The
///         market transfers collateral here first (settle-before-swap), then calls `sellCollateral`;
///         the venue swaps exact-in collateral->USDC with the liquidation flag and returns the USDC.
contract V4Venue is ISwapVenue, IUnlockCallback {
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;
    PoolKey public key;
    address public immutable market;
    address public immutable admin; // may set the pool key once (the deployer/governance)
    Currency public immutable collateral;
    Currency public immutable debt;
    bool public immutable zeroForOne; // true when collateral is currency0

    uint256 private constant ACTIVE_SLOT = 0xa07aac71; // transient "liquidation active" flag

    error NotMarket();
    error NotManager();

    constructor(IPoolManager manager_, address market_, Currency collateral_, Currency debt_, bool zeroForOne_) {
        manager = manager_;
        market = market_;
        admin = msg.sender;
        collateral = collateral_;
        debt = debt_;
        zeroForOne = zeroForOne_;
    }

    function setKey(PoolKey calldata key_) external {
        require(msg.sender == admin, "only admin");
        key = key_;
    }

    function liquidationActive() external view returns (bool a) {
        assembly {
            a := tload(ACTIVE_SLOT)
        }
    }

    /// @notice Sell `collateralIn` (already transferred in) for at least `minDebtOut` USDC via the pool.
    function sellCollateral(uint256 collateralIn, uint256 minDebtOut) external returns (uint256 debtOut) {
        if (msg.sender != market) revert NotMarket();
        assembly {
            tstore(ACTIVE_SLOT, 1)
        }
        debtOut = abi.decode(manager.unlock(abi.encode(collateralIn, minDebtOut)), (uint256));
        assembly {
            tstore(ACTIVE_SLOT, 0)
        }
        // Forward the proceeds to the market.
        IERC20Min(Currency.unwrap(debt)).transfer(market, debtOut);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        (uint256 collateralIn, uint256 minDebtOut) = abi.decode(data, (uint256, uint256));

        BalanceDelta delta = manager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(collateralIn),
                sqrtPriceLimitX96: zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341
            }),
            abi.encode(BackstopHook.HookData({isLiquidation: true}))
        );
        return abi.encode(_settle(delta, minDebtOut));
    }

    /// @dev Settle the collateral owed, take and return the USDC due (enforcing minOut).
    function _settle(BalanceDelta delta, uint256 minDebtOut) private returns (uint256 debtOut) {
        int256 colDelta = zeroForOne ? int256(delta.amount0()) : int256(delta.amount1());
        int256 debtDelta = zeroForOne ? int256(delta.amount1()) : int256(delta.amount0());
        if (colDelta < 0) collateral.settle(manager, address(this), uint256(-colDelta), false);
        debtOut = debtDelta > 0 ? uint256(debtDelta) : 0;
        require(debtOut >= minDebtOut, "minOut");
        if (debtOut > 0) debt.take(manager, address(this), debtOut, false);
    }
}
