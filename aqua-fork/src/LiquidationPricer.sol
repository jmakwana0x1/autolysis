// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SwapQuery, SwapRegisters} from "@1inch/swap-vm/contracts/libs/VM.sol";
import {IExtruction, IStaticExtruction} from "@1inch/swap-vm/contracts/instructions/interfaces/IExtruction.sol";

/// Minimal RoundFeed view: price is debt-token units per 1e18 of collateral (WETH), 1e18-scaled.
/// On the real stack this is src/core/RoundFeed.sol (solc 0.8.26); the fork defines its own view so the
/// 0.8.30 SwapVM build does not import the 0.8.26 tree. On a fork the maker points the pricer at the
/// deployed RoundFeed address, which must expose this selector (TODO(ask): confirm the live RoundFeed
/// read selector/semantics before wiring on the devnet).
interface IPriceSource {
    function price() external view returns (uint256 debtPerColl1e18);
}

/// @title LiquidationPricer
/// @notice A SwapVM Extruction target that prices a liquidation swap from the RoundFeed oracle instead
///         of from pool reserves. Because the rate comes from the oracle, the fill is independent of the
///         maker's shipped balances and cannot be moved by a sandwich: a front-run swap changes pool
///         state, not the oracle, so the liquidator pays the oracle rate regardless. quote and swap run
///         the same pure math (both interfaces delegate to `_price`), so a taker's quote equals its fill.
/// @dev Encoding of the Extruction args the maker ships: [address priceSource, address collateral].
///      `collateral` names which side of the pair is WETH; the other side is the debt token. The opcode
///      runs with amountIn (exact-in) or amountOut (exact-out) already loaded by the taker; this fills
///      the opposite register from the oracle rate and consumes no taker args.
contract LiquidationPricer is IExtruction, IStaticExtruction {
    uint256 internal constant ONE = 1e18;

    error ZeroPrice();
    error ExactOutUnsupported();

    function extruction(
        bool,
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegisters calldata swap,
        bytes calldata args,
        bytes calldata
    ) external view override(IExtruction, IStaticExtruction) returns (uint256, uint256, SwapRegisters memory) {
        return (nextPC, 0, _price(query, swap, args));
    }

    function _price(SwapQuery calldata query, SwapRegisters calldata swap, bytes calldata args)
        internal
        view
        returns (SwapRegisters memory out)
    {
        (address priceSource, address collateral) = _parse(args);
        uint256 p = IPriceSource(priceSource).price(); // debt per 1e18 collateral
        if (p == 0) revert ZeroPrice();

        out = swap;
        // Only exact-in is modeled: a liquidation delivers a known amountIn and takes whatever the oracle
        // yields. Exact-out would need the inverse and a different min-rate guard; reject it loudly.
        if (!query.isExactIn) revert ExactOutUnsupported();

        if (query.tokenIn == collateral) {
            // Selling collateral (WETH) for debt token: amountOut = amountIn * price / 1e18.
            out.amountOut = (swap.amountIn * p) / ONE;
        } else {
            // Paying debt token for collateral (WETH): amountOut = amountIn * 1e18 / price.
            out.amountOut = (swap.amountIn * ONE) / p;
        }
    }

    function _parse(bytes calldata args) internal pure returns (address priceSource, address collateral) {
        require(args.length == 40, "pricer args");
        priceSource = address(bytes20(args[0:20]));
        collateral = address(bytes20(args[20:40]));
    }
}
