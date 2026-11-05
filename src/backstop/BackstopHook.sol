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
    function liquidationPrice() external view returns (uint256);
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

        uint256 consumedCol;
        uint256 usdcOut;
        {
            uint256 collateralOffered = uint256(-params.amountSpecified);
            (consumedCol, usdcOut) = _waterfall(sender, inputCurrency, collateralOffered);
        }
        if (consumedCol == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // The venue settled the collateral into the manager BEFORE the swap, so the makers and the house
        // were paid real collateral inside _waterfall (via take with claims=false). Here the hook only
        // settles the USDC it sourced. The hook holds no ERC-6909 claims afterward (C4/N4).
        outputCurrency.settle(manager, address(this), usdcOut, false); // real USDC -> manager

        BeforeSwapDelta delta = toBeforeSwapDelta(int128(int256(consumedCol)), -int128(int256(usdcOut)));
        return (IHooks.beforeSwap.selector, delta, 0);
    }

    /// @dev Three-tier waterfall. Pays makers and the house their collateral in REAL tokens as it fills
    ///      (the venue pre-settled the collateral into the manager), and returns the collateral consumed
    ///      by tiers 1+2 and the USDC sourced for it. Everything prices at the liquidation's cited round.
    function _waterfall(address venue, Currency inputCurrency, uint256 collateralOffered)
        internal
        returns (uint256 consumedCol, uint256 usdcOut)
    {
        uint256 roundPrice = ILiquidationCaller(venue).liquidationPrice();
        uint256 remaining = collateralOffered;
        uint256 tier1Usdc;
        uint256 tier2Usdc;

        // Tier 1: Aqua makers. The router pulls USDC from maker wallets into the hook and reports each
        // maker's collateral share; the hook pays that share straight to the maker's wallet.
        if (address(router) != address(0)) {
            (uint256 u1, uint256 c1) = _tier1(inputCurrency, remaining, roundPrice);
            tier1Usdc = u1;
            consumedCol += c1;
            remaining -= c1;
        }

        // Tier 2: the house deposits tier (priced at the cited round, N8), only when tier 1 fell short.
        if (remaining > 0 && depositsOf[debtCurrency] > 0) {
            uint256 capCol = AquaPricing.collateralForUsdc(depositsOf[debtCurrency], roundPrice);
            uint256 c2 = capCol < remaining ? capCol : remaining;
            uint256 u2 = AquaPricing.usdcForCollateral(c2, roundPrice);
            if (u2 > depositsOf[debtCurrency]) u2 = depositsOf[debtCurrency];
            depositsOf[debtCurrency] -= u2;
            if (c2 > 0) inputCurrency.take(manager, owner, c2, false); // house collateral -> owner, real
            tier2Usdc = u2;
            consumedCol += c2;
            remaining -= c2;
        }

        usdcOut = tier1Usdc + tier2Usdc;
        emit Waterfall(venue, tier1Usdc, tier2Usdc, remaining);
    }

    /// @dev Tier 1: fill from Aqua makers at the cited price, paying each its collateral share in real
    ///      tokens. Returns USDC raised and collateral used.
    function _tier1(Currency inputCurrency, uint256 remaining, uint256 roundPrice)
        internal
        returns (uint256 usdcOut, uint256 colUsed)
    {
        router.setGate(true);
        (uint256 u1, uint256 c1, AutolysisAquaRouter.Payout[] memory payouts) =
            router.fill(remaining, address(this), roundPrice);
        router.setGate(false);
        if (c1 > remaining) c1 = remaining;
        for (uint256 i; i < payouts.length; ++i) {
            if (payouts[i].collateral > 0) {
                inputCurrency.take(manager, payouts[i].recipient, payouts[i].collateral, false);
            }
        }
        return (u1, c1);
    }

    function _decode(bytes calldata hookData) internal pure returns (HookData memory hd) {
        if (hookData.length == 0) return hd;
        hd = abi.decode(hookData, (HookData));
    }
}
