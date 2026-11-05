// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "./BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "v4-core-test/utils/CurrencySettler.sol";
import {IERC20Min} from "../interfaces/IERC20Min.sol";

/// @title BackstopHook
/// @notice Uniswap v4 hook that backstops Autolysis liquidations. For a registered market's liquidation
///         swap (flagged in hookData), it fills the swap from the hook's own deposits tier using custom
///         accounting; for any other swapper it returns ZERO_DELTA so the pool behaves exactly like a
///         vanilla pool. Guarantees: deltas net to zero; an outside swapper sees a normal pool; an
///         unregistered caller follows the vanilla path; settle-before-swap; reentrancy is blocked.
/// @dev Phase 3 fills only from the deposits tier. Phase 4 inserts the Aqua maker waterfall ahead of
///      deposits (tier 1 makers, tier 2 deposits, tier 3 vanilla curve) in `_fillLiquidation`.
contract BackstopHook is BaseHook {
    using CurrencySettler for Currency;

    struct HookData {
        bool isLiquidation;
        address market;
    }

    address public immutable owner;
    mapping(address => bool) public registeredMarket;

    // Deposits tier: currency balances the hook holds to fill liquidations (settled via ERC-6909 claims).
    mapping(Currency => uint256) public depositsOf;

    bool private _entered;

    error NotOwner();
    error Reentrancy();

    event MarketRegistered(address indexed market, bool allowed);
    event Deposited(Currency indexed currency, uint256 amount);
    event BackstopFilled(address indexed market, uint256 amountIn, uint256 amountOut);

    constructor(IPoolManager manager_, address owner_) BaseHook(manager_) {
        owner = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_entered) revert Reentrancy();
        _entered = true;
        _;
        _entered = false;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
        p.beforeSwapReturnDelta = true;
        p.beforeAddLiquidity = true;
    }

    function setMarket(address market, bool allowed) external onlyOwner {
        registeredMarket[market] = allowed;
        emit MarketRegistered(market, allowed);
    }

    /// @notice Fund the deposits tier. The hook mints ERC-6909 claims against the manager so it can
    ///         settle liquidation fills without moving real tokens each time.
    function deposit(Currency currency, uint256 amount) external {
        // The hook holds raw tokens for the deposits tier and settles fills with burn=false (a real
        // transfer to the manager), mirroring the v4 custom-curve model.
        IERC20Min(Currency.unwrap(currency)).transferFrom(msg.sender, address(this), amount);
        depositsOf[currency] += amount;
        emit Deposited(currency, amount);
    }

    /// @notice beforeSwap: for a registered-market liquidation, fill from deposits with custom
    ///         accounting; otherwise ZERO_DELTA (vanilla pool path).
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        HookData memory hd = _decode(hookData);
        if (!hd.isLiquidation || !registeredMarket[hd.market]) {
            // Outside swapper / unregistered market: no custom accounting, normal pool.
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Phase 3 fills exact-input liquidations fully from the deposits tier, 1:1 in currency units
        // (the venue values collateral at the oracle price before calling, so the pool leg is a
        // par swap). If deposits cannot cover the whole input, fall through to the vanilla curve so the
        // delta stays clean; the partial-tier waterfall is Phase 4.
        if (params.amountSpecified >= 0) {
            // exact-output liquidations are not used; let the vanilla curve handle them.
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        (Currency inputCurrency, Currency outputCurrency, uint256 amount) = _io(key, params);
        if (amount > depositsOf[outputCurrency]) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // settle-before-swap: resolve the input leg first (mint ERC-6909 claims for the input the taker
        // owes, so no real tokens are pulled from the pool's reserves), then settle the output out of the
        // deposits tier with a real transfer. The input is accounted before the output leaves.
        inputCurrency.take(manager, address(this), amount, true); // mint claims for the input
        depositsOf[inputCurrency] += amount; // tracked as claim-backed balance
        depositsOf[outputCurrency] -= amount;
        outputCurrency.settle(manager, address(this), amount, false); // real transfer of output to manager

        emit BackstopFilled(hd.market, amount, amount);

        // Fully no-op the concentrated-liquidity swap: specified delta = -amountSpecified, unspecified
        // = +amountSpecified (mirrors the v4 custom-curve model for an exact-input swap).
        BeforeSwapDelta delta = toBeforeSwapDelta(int128(-params.amountSpecified), int128(params.amountSpecified));
        return (IHooks.beforeSwap.selector, delta, 0);
    }

    function _io(PoolKey calldata key, SwapParams calldata params)
        internal
        pure
        returns (Currency input, Currency output, uint256 amount)
    {
        (input, output) = params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        amount = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
    }

    function _decode(bytes calldata hookData) internal pure returns (HookData memory hd) {
        if (hookData.length == 0) return hd;
        hd = abi.decode(hookData, (HookData));
    }
}
