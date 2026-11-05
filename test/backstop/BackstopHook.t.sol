// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BackstopHook} from "../../src/backstop/BackstopHook.sol";
import {AutolysisAquaRouter} from "../../src/aqua/AutolysisAquaRouter.sol";
import {MakerFactory} from "../../src/aqua/MakerFactory.sol";
import {WalletMakerStrategy} from "../../src/aqua/WalletMakerStrategy.sol";
import {IMakerStrategy} from "../../src/aqua/IMakerStrategy.sol";
import {RoundFeed} from "../../src/core/RoundFeed.sol";
import {IRoundFeed} from "../../src/interfaces/IRoundFeed.sol";
import {IERC20Min} from "../../src/interfaces/IERC20Min.sol";

/// @notice Phase 3+4 backstop: deposits tier, Aqua maker tier, and the three-tier waterfall.
contract BackstopHookTest is Test, Deployers {
    BackstopHook hook;
    PoolKey hookKey;
    PoolKey vanillaKey;
    RoundFeed feed;
    AutolysisAquaRouter router;
    MakerFactory factory;
    address constant MARKET = address(0x3A12E7);
    address maker = address(0xAABB);

    uint160 constant FLAGS =
        uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        // currency1 is the debt (USDC) side; currency0 is collateral. Oracle: 1 collateral = 1 USDC.
        feed = new RoundFeed(address(this), 1e18);

        address hookAddr = address(FLAGS);
        BackstopHook impl = new BackstopHook(manager, address(this), IRoundFeed(address(feed)), currency1);
        vm.etch(hookAddr, address(impl).code);
        hook = BackstopHook(hookAddr);

        router = new AutolysisAquaRouter(
            IRoundFeed(address(feed)),
            IERC20Min(Currency.unwrap(currency1)),
            IERC20Min(Currency.unwrap(currency0)),
            address(this)
        );
        router.setHook(hookAddr);
        factory = new MakerFactory();
        router.allowTemplate(factory.cloneCodehash(), true);
        hook.setRouter(router);

        (hookKey,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(hookAddr), 3000, SQRT_PRICE_1_1);
        (vanillaKey,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);
    }

    function _liq() internal pure returns (bytes memory) {
        return abi.encode(BackstopHook.HookData({isLiquidation: true, market: MARKET}));
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amt, bytes memory hd) internal returns (BalanceDelta) {
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amt,
                sqrtPriceLimitX96: zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hd
        );
    }

    function _fundDeposits(uint256 amt) internal {
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));
        t1.mint(address(this), amt);
        t1.approve(address(hook), type(uint256).max);
        hook.deposit(currency1, amt);
    }

    function _addMaker(uint256 fund, uint256 maxSize) internal {
        address m = factory.create(IERC20Min(Currency.unwrap(currency1)), maker, address(router), maxSize);
        MockERC20(Currency.unwrap(currency1)).mint(maker, fund);
        vm.prank(maker);
        MockERC20(Currency.unwrap(currency1)).approve(m, type(uint256).max);
        router.registerMaker(IMakerStrategy(m), 0);
    }

    // Outside swapper sees a normal pool: matches the vanilla pool to the wei.
    function test_outsideSwapperMatchesVanilla() public {
        BalanceDelta h = _swap(hookKey, true, -1e15, "");
        BalanceDelta v = _swap(vanillaKey, true, -1e15, "");
        assertEq(h.amount0(), v.amount0());
        assertEq(h.amount1(), v.amount1());
    }

    // Unregistered market follows the vanilla path.
    function test_unregisteredMarketVanillaPath() public {
        _fundDeposits(10e18);
        BalanceDelta h = _swap(hookKey, true, -1e15, _liq());
        BalanceDelta v = _swap(vanillaKey, true, -1e15, "");
        assertEq(h.amount1(), v.amount1());
    }

    // Deposits tier fills the whole liquidation when no makers exist (tier 2 only).
    function test_depositsTierFill() public {
        hook.setMarket(MARKET, true);
        _fundDeposits(10e18);
        uint256 houseBefore = hook.houseCollateral();
        BalanceDelta d = _swap(hookKey, true, -1e15, _liq());
        assertEq(d.amount0(), -int128(1e15), "all collateral consumed by hook");
        assertEq(d.amount1(), int128(1e15), "usdc out at 1:1 oracle price");
        assertEq(hook.houseCollateral(), houseBefore + 1e15, "deposits tier should book the collateral");
        assertEq(hook.makerCollateralOwed(), 0, "no makers used");
    }

    // Waterfall order: makers (tier 1) are used before deposits (tier 2); the remainder hits the curve.
    function test_waterfallOrder() public {
        hook.setMarket(MARKET, true);
        _addMaker(0.4e15, 0.4e15); // maker covers 0.4e15 collateral (at 1:1)
        _fundDeposits(0.4e15); // deposits cover another 0.4e15
        // Sell 1e15 collateral: 0.4 makers + 0.4 deposits + 0.2 curve.
        BalanceDelta d = _swap(hookKey, true, -1e15, _liq());

        assertEq(hook.makerCollateralOwed(), 0.4e15, "tier 1 (makers) should fill first");
        assertEq(hook.houseCollateral(), 0.4e15, "tier 2 (deposits) fills the next slice");
        // Hook consumed 0.8e15 collateral for 0.8e15 USDC; the remaining 0.2e15 went to the curve.
        assertLt(d.amount1(), int128(1e15), "curve leg returns less than par due to price impact");
        assertGt(d.amount1(), int128(0.8e15), "but more than just the backstop slice");
    }

    // Tier 2 is NOT touched when tier 1 covers the whole sale.
    function test_tier2UntouchedWhenMakersCover() public {
        hook.setMarket(MARKET, true);
        _addMaker(10e18, 10e18); // makers can cover everything
        _fundDeposits(10e18);
        _swap(hookKey, true, -1e15, _liq());
        assertEq(hook.makerCollateralOwed(), 1e15, "makers cover the full sale");
        assertEq(hook.houseCollateral(), 0, "deposits tier must stay untouched");
    }

    // Oracle pricing: at 2 USDC per collateral, selling 1e15 collateral yields 2e15 USDC from deposits.
    function test_oraclePricedDepositsFill() public {
        feed.post(2e18);
        hook.setMarket(MARKET, true);
        _fundDeposits(10e18);
        BalanceDelta d = _swap(hookKey, true, -1e15, _liq());
        assertEq(d.amount0(), -int128(1e15));
        assertEq(d.amount1(), int128(2e15), "2 USDC per collateral");
    }

    // Both currency orderings: a pool where collateral is currency1 and debt is currency0 also fills.
    function test_bothCurrencyOrders() public {
        address hookAddr2 = address(uint160(uint160(FLAGS) | (0x1234 << 20)));
        BackstopHook impl2 = new BackstopHook(manager, address(this), IRoundFeed(address(feed)), currency0);
        vm.etch(hookAddr2, address(impl2).code);
        BackstopHook hook2 = BackstopHook(hookAddr2);
        hook2.setMarket(MARKET, true);
        (PoolKey memory k2,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(hookAddr2), 3000, SQRT_PRICE_1_1);

        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        t0.mint(address(this), 10e18);
        t0.approve(address(hook2), type(uint256).max);
        hook2.deposit(currency0, 10e18);

        // Sell currency1 (collateral) for currency0 (debt): zeroForOne=false.
        BalanceDelta d = _swap(k2, false, -1e15, _liq());
        assertEq(d.amount1(), -int128(1e15), "collateral (currency1) consumed");
        assertEq(d.amount0(), int128(1e15), "debt (currency0) out at 1:1");
        assertEq(hook2.houseCollateral(), 1e15);
    }

    // Pool manipulation is harmless: the backstop fill is oracle-priced, not pool-priced.
    function test_poolManipulationHarmless() public {
        hook.setMarket(MARKET, true);
        _fundDeposits(100e18);
        _swap(hookKey, true, -5e17, ""); // attacker shoves the pool price
        BalanceDelta d = _swap(hookKey, true, -1e15, _liq());
        assertEq(d.amount1(), int128(1e15), "oracle-priced fill unaffected by pool price");
    }

    // Deltas net to zero for every backstop swap (the unlock reverts otherwise), both directions.
    function testFuzz_deltasNetToZero(uint96 amt, bool withMaker) public {
        hook.setMarket(MARKET, true);
        uint256 a = bound(uint256(amt), 1e9, 1e17);
        _fundDeposits(1e18);
        if (withMaker) _addMaker(1e18, 1e18);
        _swap(hookKey, true, -int256(a), _liq());
    }
}
