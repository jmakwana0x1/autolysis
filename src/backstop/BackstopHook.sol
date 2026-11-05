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

/// @notice Minimal view the hook needs of whoever drives the swap: whether a liquidation is active.
interface ILiquidationCaller {
    function liquidationActive() external view returns (bool);
}

/// @title BackstopHook
/// @notice Uniswap v4 hook backstopping Autolysis liquidations with a three-tier waterfall: Aqua makers
///         first, then the hook's own deposits, then the vanilla curve. Guarantees:
///         - Only a registered venue, and only while that venue reports an active liquidation, is filled;
///           any other swapper sees a normal pool (ZERO_DELTA). Authorization is on `sender`, never on
///           self-declared `hookData` (C3), so hookData carries only the liquidation flag.
///         - Deltas net to zero; settle-before-swap; reentrancy blocked.
///         - Makers and the house are paid their collateral as ERC-6909 claims in the same fill (C4), so
///           the hook holds no collateral claims after a swap.
///         - Tier 2 is touched only when tier 1 cannot cover, tier 3 only when neither can.
/// @dev Output currency is the debt token (USDC); input is collateral. Only exact-input liquidations are
///      backstopped; everything else is ZERO_DELTA.
contract BackstopHook is BaseHook {
    using CurrencySettler for Currency;

    struct HookData {
        bool isLiquidation;
    }

    address public immutable owner;
    IRoundFeed public immutable feed;
    Currency public immutable debtCurrency;
    AutolysisAquaRouter public router;

    mapping(address => bool) public registeredVenue; // the authorized swap callers (sender)
    mapping(Currency => uint256) public depositsOf; // house deposits tier, by currency

    bool private _entered;

    error NotOwner();
    error Reentrancy();

    event VenueRegistered(address indexed venue, bool allowed);
    event Deposited(Currency indexed currency, uint256 amount);
    event Waterfall(address indexed venue, uint256 tier1Usdc, uint256 tier2Usdc, uint256 tier3Collateral);

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

    /// @notice Register (or revoke) a venue whose liquidation swaps the hook will backstop.
    function setVenue(address venue, bool allowed) external onlyOwner {
        registeredVenue[venue] = allowed;
        emit VenueRegistered(venue, allowed);
    }

    function setRouter(AutolysisAquaRouter router_) external onlyOwner {
        router = router_;
    }

    function deposit(Currency currency, uint256 amount) external {
        IERC20Min(Currency.unwrap(currency)).transferFrom(msg.sender, address(this), amount);
        depositsOf[currency] += amount;
        emit Deposited(currency, amount);
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        HookData memory hd = _decode(hookData);
        // Authorize on the caller, not on hookData: only a registered venue mid-liquidation is filled.
        bool authorized = hd.isLiquidation && registeredVenue[sender] && ILiquidationCaller(sender).liquidationActive();
        if (!authorized || params.amountSpecified >= 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        (Currency inputCurrency, Currency outputCurrency) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        if (Currency.unwrap(outputCurrency) != Currency.unwrap(debtCurrency)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 collateralOffered = uint256(-params.amountSpecified);
        (uint256 consumedCol, uint256 usdcOut) = _waterfall(sender, inputCurrency, collateralOffered);
        if (consumedCol == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // settle-before-swap: resolve the input leg as claims (no reserve draw), then settle the sourced
        // USDC out to the manager. The collateral claims are fully distributed inside _waterfall, so the
        // hook holds none afterward.
        inputCurrency.take(manager, address(this), consumedCol, true); // mint collateral claims
        _distribute(inputCurrency, consumedCol);
        outputCurrency.settle(manager, address(this), usdcOut, false); // real USDC -> manager

        BeforeSwapDelta delta = toBeforeSwapDelta(int128(int256(consumedCol)), -int128(int256(usdcOut)));
        return (IHooks.beforeSwap.selector, delta, 0);
    }

    // transient per-fill distribution plan: maker payouts collected during the waterfall, paid after the
    // claims are minted. Kept in memory via storage arrays cleared each fill.
    AutolysisAquaRouter.Payout[] private _pendingPayouts;
    uint256 private _houseCollateral;

    /// @dev Three-tier waterfall. Returns collateral consumed by tiers 1+2 and the USDC sourced for it,
    ///      and records how that collateral is split between makers and the house for `_distribute`.
    function _waterfall(address venue, Currency, uint256 collateralOffered)
        internal
        returns (uint256 consumedCol, uint256 usdcOut)
    {
        delete _pendingPayouts;
        _houseCollateral = 0;
        uint256 remaining = collateralOffered;
        uint256 tier1Usdc;
        uint256 tier2Usdc;

        // Tier 1: Aqua makers. The router pulls USDC from maker wallets into the hook and reports each
        // maker's collateral share; the gate is opened only for this call.
        if (address(router) != address(0)) {
            router.setGate(true);
            (uint256 u1, uint256 c1, AutolysisAquaRouter.Payout[] memory payouts) =
                router.fill(remaining, address(this));
            router.setGate(false);
            if (c1 > remaining) c1 = remaining;
            for (uint256 i; i < payouts.length; ++i) {
                _pendingPayouts.push(payouts[i]);
            }
            tier1Usdc = u1;
            consumedCol += c1;
            remaining -= c1;
        }

        // Tier 2: the house deposits tier, only when tier 1 could not cover the whole sale.
        if (remaining > 0 && depositsOf[debtCurrency] > 0) {
            uint256 eff = feed.getRound(feed.latestRound()).price;
            uint256 capCol = AquaPricing.collateralForUsdc(depositsOf[debtCurrency], eff);
            uint256 c2 = capCol < remaining ? capCol : remaining;
            uint256 u2 = AquaPricing.usdcForCollateral(c2, eff);
            if (u2 > depositsOf[debtCurrency]) u2 = depositsOf[debtCurrency];
            depositsOf[debtCurrency] -= u2;
            _houseCollateral = c2;
            tier2Usdc = u2;
            consumedCol += c2;
            remaining -= c2;
        }

        usdcOut = tier1Usdc + tier2Usdc;
        emit Waterfall(venue, tier1Usdc, tier2Usdc, remaining);
    }

    /// @dev Pay out the collateral claims the hook just minted: makers to their wallets, the house share
    ///      to the owner. Both as ERC-6909 claims (redeemable from the manager), so the hook ends the
    ///      fill holding zero collateral claims.
    function _distribute(Currency inputCurrency, uint256) internal {
        uint256 id = uint256(uint160(Currency.unwrap(inputCurrency))); // CurrencyLibrary.toId
        uint256 len = _pendingPayouts.length;
        for (uint256 i; i < len; ++i) {
            AutolysisAquaRouter.Payout memory po = _pendingPayouts[i];
            if (po.collateral > 0) manager.transfer(po.recipient, id, po.collateral);
        }
        if (_houseCollateral > 0) manager.transfer(owner, id, _houseCollateral);
        delete _pendingPayouts;
        _houseCollateral = 0;
    }

    function _decode(bytes calldata hookData) internal pure returns (HookData memory hd) {
        if (hookData.length == 0) return hd;
        hd = abi.decode(hookData, (HookData));
    }
}
