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
import {IRoundFeed} from "../interfaces/IRoundFeed.sol";
import {AutolysisAquaRouter} from "../aqua/AutolysisAquaRouter.sol";
import {AquaPricing} from "../aqua/AquaPricing.sol";

/// @title BackstopHook
/// @notice Uniswap v4 hook backstopping Autolysis liquidations with a three-tier waterfall: Aqua makers
///         first, then the hook's own deposits, then the vanilla curve. Guarantees: deltas net to zero;
///         an outside swapper / unregistered market sees a normal pool (ZERO_DELTA); settle-before-swap;
///         reentrancy blocked; tier 2 is only touched when tier 1 cannot cover, tier 3 only when neither
///         can. The collateral the taker sells is priced in the output currency by the oracle; makers
///         and deposits fill at that price, and any remainder flows to the concentrated-liquidity curve.
/// @dev The output currency is the debt token (USDC). The input currency is collateral. Only exact-input
///      liquidations are backstopped; everything else is ZERO_DELTA.
contract BackstopHook is BaseHook {
    using CurrencySettler for Currency;

    struct HookData {
        bool isLiquidation;
        address market;
    }

    address public immutable owner;
    IRoundFeed public immutable feed;
    Currency public immutable debtCurrency; // the output (USDC) side
    AutolysisAquaRouter public router;

    mapping(address => bool) public registeredMarket;
    mapping(Currency => uint256) public depositsOf; // house deposits tier, by currency
    uint256 public makerCollateralOwed; // collateral claims accrued to makers (withdrawable)
    uint256 public houseCollateral; // collateral claims the house earned via its deposits tier

    bool private _entered;

    error NotOwner();
    error Reentrancy();

    event MarketRegistered(address indexed market, bool allowed);
    event Deposited(Currency indexed currency, uint256 amount);
    event Waterfall(address indexed market, uint256 tier1Usdc, uint256 tier2Usdc, uint256 tier3Collateral);

    constructor(IPoolManager manager_, address owner_, IRoundFeed feed_, Currency debtCurrency_) BaseHook(manager_) {
        owner = owner_;
        feed = feed_;
        debtCurrency = debtCurrency_;
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

    function setRouter(AutolysisAquaRouter router_) external onlyOwner {
        router = router_;
    }

    function deposit(Currency currency, uint256 amount) external {
        IERC20Min(Currency.unwrap(currency)).transferFrom(msg.sender, address(this), amount);
        depositsOf[currency] += amount;
        emit Deposited(currency, amount);
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        HookData memory hd = _decode(hookData);
        if (!hd.isLiquidation || !registeredMarket[hd.market] || params.amountSpecified >= 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        (Currency inputCurrency, Currency outputCurrency) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        // Only backstop the collateral->debt direction (output must be the debt currency).
        if (Currency.unwrap(outputCurrency) != Currency.unwrap(debtCurrency)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 collateralOffered = uint256(-params.amountSpecified);
        (uint256 consumedCol, uint256 usdcOut) = _waterfall(hd.market, collateralOffered);
        if (consumedCol == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // settle-before-swap: resolve the input leg as claims (no reserve draw), then settle the USDC we
        // sourced out to the manager. consumedCol collateral is taken; usdcOut debt token is paid.
        inputCurrency.take(manager, address(this), consumedCol, true); // mint collateral claims
        outputCurrency.settle(manager, address(this), usdcOut, false); // real USDC -> manager

        // Any remainder (collateralOffered - consumedCol) flows to the vanilla curve.
        BeforeSwapDelta delta = toBeforeSwapDelta(int128(int256(consumedCol)), -int128(int256(usdcOut)));
        return (IHooks.beforeSwap.selector, delta, 0);
    }

    /// @dev Three-tier waterfall. Returns collateral consumed by tiers 1+2 and the USDC sourced for it.
    function _waterfall(address market, uint256 collateralOffered)
        internal
        returns (uint256 consumedCol, uint256 usdcOut)
    {
        uint256 remaining = collateralOffered;
        uint256 tier1Usdc;
        uint256 tier2Usdc;

        // Tier 1: Aqua makers (if a router is set). The router pulls USDC from maker wallets into the
        // hook and reports the collateral it consumed; that collateral is owed to makers.
        if (address(router) != address(0)) {
            router.setGate(true);
            (uint256 u1, uint256 c1) = router.fill(remaining, address(this));
            router.setGate(false);
            if (c1 > remaining) c1 = remaining; // defensive
            tier1Usdc = u1;
            makerCollateralOwed += c1;
            consumedCol += c1;
            remaining -= c1;
        }

        // Tier 2: the house deposits tier, only when tier 1 could not cover the whole sale.
        if (remaining > 0 && depositsOf[debtCurrency] > 0) {
            uint256 eff = feed.getRound(feed.latestRound()).price; // house fills at the oracle price
            uint256 capCol = AquaPricing.collateralForUsdc(depositsOf[debtCurrency], eff);
            uint256 c2 = capCol < remaining ? capCol : remaining;
            uint256 u2 = AquaPricing.usdcForCollateral(c2, eff);
            if (u2 > depositsOf[debtCurrency]) u2 = depositsOf[debtCurrency];
            depositsOf[debtCurrency] -= u2;
            houseCollateral += c2;
            tier2Usdc = u2;
            consumedCol += c2;
            remaining -= c2;
        }

        usdcOut = tier1Usdc + tier2Usdc;
        // Tier 3 is whatever remains (handled by the vanilla curve via the leftover specified amount).
        emit Waterfall(market, tier1Usdc, tier2Usdc, remaining);
    }

    function _decode(bytes calldata hookData) internal pure returns (HookData memory hd) {
        if (hookData.length == 0) return hd;
        hd = abi.decode(hookData, (HookData));
    }
}
