// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BackstopHook} from "../../src/backstop/BackstopHook.sol";

/// @notice Phase 3 Uniswap backstop invariants. Run for both currency orderings via `_order`.
contract BackstopHookTest is Test, Deployers {
    BackstopHook hook;
    PoolKey hookKey;
    PoolKey vanillaKey;
    address constant MARKET = address(0x3A12E7);

    uint160 constant FLAGS =
        uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        address hookAddr = address(FLAGS);
        BackstopHook impl = new BackstopHook(manager, address(this));
        vm.etch(hookAddr, address(impl).code);
        hook = BackstopHook(hookAddr);

        (hookKey,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(hookAddr), 3000, SQRT_PRICE_1_1);
        (vanillaKey,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);
    }

    function _liqData() internal pure returns (bytes memory) {
        return abi.encode(BackstopHook.HookData({isLiquidation: true, market: MARKET}));
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    // Outside swapper (no hook data) sees a normal pool: result matches the vanilla pool to the wei.
    function test_outsideSwapperMatchesVanilla() public {
        BalanceDelta h = _swap(hookKey, true, -1e15, "");
        BalanceDelta v = _swap(vanillaKey, true, -1e15, "");
        assertEq(h.amount0(), v.amount0(), "amount0 differs from vanilla");
        assertEq(h.amount1(), v.amount1(), "amount1 differs from vanilla");
    }

    // An unregistered market's liquidation data follows the vanilla path (ZERO_DELTA).
    function test_unregisteredMarketVanillaPath() public {
        // MARKET not registered yet.
        BalanceDelta h = _swap(hookKey, true, -1e15, _liqData());
        BalanceDelta v = _swap(vanillaKey, true, -1e15, "");
        assertEq(h.amount0(), v.amount0());
        assertEq(h.amount1(), v.amount1());
    }

    // A registered-market liquidation fills from the deposits tier (1:1), not the curve.
    function test_registeredLiquidationFillsFromDeposits() public {
        hook.setMarket(MARKET, true);
        // Fund the deposits tier with currency1 (the output when selling currency0).
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));
        t1.mint(address(this), 10e18);
        t1.approve(address(hook), type(uint256).max);
        hook.deposit(currency1, 10e18);

        uint256 depBefore0 = hook.depositsOf(currency0);
        uint256 depBefore1 = hook.depositsOf(currency1);

        // Sell 1e15 of currency0 for currency1, flagged as a registered liquidation.
        BalanceDelta d = _swap(hookKey, true, -1e15, _liqData());

        // Par fill: exactly 1e15 out, 1e15 in consumed by the hook.
        assertEq(hook.depositsOf(currency0), depBefore0 + 1e15, "input not added to deposits");
        assertEq(hook.depositsOf(currency1), depBefore1 - 1e15, "output not drawn from deposits");
        assertEq(d.amount0(), -int128(1e15), "unexpected amount0");
        assertEq(d.amount1(), int128(1e15), "unexpected amount1 (should be par 1:1)");
    }

    // When deposits cannot cover the swap, it falls through to the vanilla curve (clean delta).
    function test_insufficientDepositsFallsThrough() public {
        hook.setMarket(MARKET, true);
        BalanceDelta h = _swap(hookKey, true, -1e15, _liqData()); // deposits empty -> vanilla
        BalanceDelta v = _swap(vanillaKey, true, -1e15, "");
        assertEq(h.amount1(), v.amount1(), "should match vanilla when deposits can't cover");
    }

    // Both currency orderings: selling currency1 for currency0 fills from the currency0 deposits tier.
    function test_registeredLiquidationOtherOrder() public {
        hook.setMarket(MARKET, true);
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        t0.mint(address(this), 10e18);
        t0.approve(address(hook), type(uint256).max);
        hook.deposit(currency0, 10e18);

        uint256 dep0 = hook.depositsOf(currency0);
        uint256 dep1 = hook.depositsOf(currency1);
        BalanceDelta d = _swap(hookKey, false, -1e15, _liqData()); // sell currency1 for currency0
        assertEq(hook.depositsOf(currency1), dep1 + 1e15, "input (currency1) not added");
        assertEq(hook.depositsOf(currency0), dep0 - 1e15, "output (currency0) not drawn");
        assertEq(d.amount1(), -int128(1e15));
        assertEq(d.amount0(), int128(1e15));
    }

    // Pool-manipulation attack is harmless: moving the pool price does not change the par backstop fill.
    function test_poolManipulationHarmless() public {
        hook.setMarket(MARKET, true);
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));
        t1.mint(address(this), 100e18);
        t1.approve(address(hook), type(uint256).max);
        hook.deposit(currency1, 100e18);

        // Attacker shoves the pool price with a large vanilla swap on the hook pool.
        _swap(hookKey, true, -5e17, "");

        // A registered liquidation still fills exactly 1:1 from deposits, unaffected by the pool price.
        uint256 dep1 = hook.depositsOf(currency1);
        BalanceDelta d = _swap(hookKey, true, -1e15, _liqData());
        assertEq(hook.depositsOf(currency1), dep1 - 1e15, "fill not par after manipulation");
        assertEq(d.amount1(), int128(1e15), "backstop fill must stay par (1:1)");
    }

    // Deltas net to zero for every swap (v4 reverts the unlock otherwise) in both directions and for
    // outside / registered callers; the hook never leaves an unsettled balance.
    function testFuzz_deltasNetToZero(uint96 amt, bool zeroForOne, bool liq, bool registered) public {
        uint256 a = bound(uint256(amt), 1e9, 1e17);
        if (registered) hook.setMarket(MARKET, true);
        // fund both tiers generously so registered fills can happen either direction
        MockERC20(Currency.unwrap(currency0)).mint(address(this), 1e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 1e18);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        hook.deposit(currency0, 1e18);
        hook.deposit(currency1, 1e18);
        // A successful router call means all deltas settled to zero; assert it does not revert.
        _swap(hookKey, zeroForOne, -int256(a), liq ? _liqData() : bytes(""));
    }
}
