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
import {ISwapVMRouter} from "../interfaces/ISwapVMRouter.sol";

/// @notice The one Aqua read tier 1 needs: a maker's balance for a shipped strategy (upstream IAqua).
interface IAquaBalances {
    function rawBalances(address maker, address app, bytes32 strategyHash, address token)
        external
        view
        returns (uint248 balance, uint8 tokensCount);
}

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

    /// Tier 1 on the real gated SwapVM router (C1). When set, it replaces the model `router` tier.
    struct SwapVMOrder {
        ISwapVMRouter.Order order; // shipped by the maker; program starts with the LiquidationGate
        bytes takerData; // exact-in taker traits; taker = recipient = this hook
    }

    ISwapVMRouter public swapVM;
    IAquaBalances public aqua;
    SwapVMOrder[] internal _swapOrders;
    /// Gas cap per maker order, so a hostile program can only skip itself, not grief the liquidation.
    uint256 public constant SWAPVM_FILL_GAS = 600_000;

    mapping(address => bool) public registeredVenue; // the authorized swap callers (sender)
    mapping(Currency => uint256) public depositsOf; // house deposits tier, by currency

    bool private _entered;

    error NotOwner();
    error Reentrancy();

    event VenueRegistered(address indexed venue, bool allowed);
    event Deposited(Currency indexed currency, uint256 amount);
    event SwapVMFilled(uint256 indexed index, address indexed maker, uint256 collateralIn, uint256 usdcOut);
    event SwapVMSkipped(uint256 indexed index, address indexed maker);
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

    /// @notice Point tier 1 at the gated SwapVM router and the Aqua registry it pulls from.
    function setSwapVM(ISwapVMRouter swapVM_, IAquaBalances aqua_) external onlyOwner {
        swapVM = swapVM_;
        aqua = aqua_;
    }

    /// @notice Register a maker's shipped order (and the hook's taker data for it) for tier 1.
    function addSwapVMOrder(ISwapVMRouter.Order calldata order, bytes calldata takerData) external onlyOwner {
        _swapOrders.push(SwapVMOrder({order: order, takerData: takerData}));
    }

    function swapVMOrderCount() external view returns (uint256) {
        return _swapOrders.length;
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

        // Tier 1: Aqua makers. Either the real gated SwapVM router (the hook is the taker; Aqua moves the
        // maker's USDC to the hook and the hook's collateral to the maker's wallet), or the model router
        // (it pulls maker USDC and reports each maker's collateral share, which the hook pays out).
        if (address(swapVM) != address(0)) {
            (uint256 u1, uint256 c1) = _tier1SwapVM(inputCurrency, remaining, roundPrice);
            tier1Usdc = u1;
            consumedCol += c1;
            remaining -= c1;
        } else if (address(router) != address(0)) {
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

    /// @dev Tier 1 through the gated SwapVM router. Per order: size the fill to the maker's Aqua USDC at
    ///      the cited price, quote it, and skip unless the quote pays at least the cited price; then take
    ///      that collateral from the manager (the venue pre-settled it), approve exactly that much, and
    ///      swap as taker. The router transfers the collateral to the maker's wallet via Aqua.push and
    ///      the maker's USDC to the hook via Aqua.pull. Unused collateral is settled back, so the hook
    ///      never keeps collateral, claims or allowance.
    function _tier1SwapVM(Currency inputCurrency, uint256 remaining, uint256 roundPrice)
        internal
        returns (uint256 usdcOut, uint256 colUsed)
    {
        uint256 n = _swapOrders.length;
        for (uint256 i; i < n && remaining > 0; ++i) {
            (uint256 spent, uint256 got) = _fillOrder(i, inputCurrency, remaining, roundPrice);
            if (spent == 0) {
                emit SwapVMSkipped(i, _swapOrders[i].order.maker);
                continue;
            }
            emit SwapVMFilled(i, _swapOrders[i].order.maker, spent, got);
            usdcOut += got;
            colUsed += spent;
            remaining -= spent;
        }
    }

    /// @dev One tier-1 order. Returns (collateral spent, USDC received); (0, 0) means skipped.
    function _fillOrder(uint256 i, Currency inputCurrency, uint256 remaining, uint256 roundPrice)
        internal
        returns (uint256 spent, uint256 got)
    {
        SwapVMOrder storage s = _swapOrders[i];
        uint256 c = _sizeFill(s.order, remaining, roundPrice, Currency.unwrap(debtCurrency));
        if (c == 0 || !_quoteFair(s, c, roundPrice)) return (0, 0);

        IERC20Min col = IERC20Min(Currency.unwrap(inputCurrency));
        IERC20Min usdc = IERC20Min(Currency.unwrap(debtCurrency));
        inputCurrency.take(manager, address(this), c, false);
        col.approve(address(swapVM), c);
        uint256 usdcBefore = usdc.balanceOf(address(this));
        try swapVM.swap{gas: SWAPVM_FILL_GAS}(s.order, c, s.takerData) returns (uint256 aIn, uint256, bytes32) {
            spent = aIn;
        } catch {}
        col.approve(address(swapVM), 0);
        got = usdc.balanceOf(address(this)) - usdcBefore;
        // A fill must pay at least the cited price for what it took (it runs the same oracle math as the
        // quote). Anything else is a broken maker program: undo the whole liquidation.
        require(got >= AquaPricing.usdcForCollateral(spent, roundPrice), "tier1 underpaid");
        if (spent < c) inputCurrency.settle(manager, address(this), c - spent, false);
        if (spent == 0) got = 0;
    }

    /// @dev The quote must take exactly `c` in and pay at least the cited price out.
    function _quoteFair(SwapVMOrder storage s, uint256 c, uint256 roundPrice) internal returns (bool) {
        try swapVM.quote{gas: SWAPVM_FILL_GAS}(s.order, c, s.takerData) returns (uint256 qIn, uint256 qOut, bytes32) {
            return qIn == c && qOut >= AquaPricing.usdcForCollateral(c, roundPrice);
        } catch {
            return false;
        }
    }

    /// @dev Largest collateral amount `order` can absorb: its maker's Aqua USDC at the cited price
    ///      (rounded down, so the fill never asks for more USDC than the maker shipped), capped at
    ///      `remaining`.
    function _sizeFill(ISwapVMRouter.Order storage order, uint256 remaining, uint256 roundPrice, address usdc)
        internal
        view
        returns (uint256 c)
    {
        if (roundPrice == 0) return 0;
        bytes32 h = swapVM.hash(order);
        (uint248 avail,) = aqua.rawBalances(order.maker, address(swapVM), h, usdc);
        c = uint256(avail) * 1e18 / roundPrice;
        if (c > remaining) c = remaining;
    }

    function _decode(bytes calldata hookData) internal pure returns (HookData memory hd) {
        if (hookData.length == 0) return hd;
        hd = abi.decode(hookData, (HookData));
    }
}
