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
import {V4Venue} from "../../src/backstop/V4Venue.sol";
import {AutolysisAquaRouter} from "../../src/aqua/AutolysisAquaRouter.sol";
import {MakerFactory} from "../../src/aqua/MakerFactory.sol";
import {IMakerStrategy} from "../../src/aqua/IMakerStrategy.sol";
import {RoundFeed} from "../../src/core/RoundFeed.sol";
import {IRoundFeed} from "../../src/interfaces/IRoundFeed.sol";
import {IERC20Min} from "../../src/interfaces/IERC20Min.sol";

/// @notice Phase 3/4 backstop with the C3/C4 rework: the hook authorizes on a registered V4Venue that is
///         mid-liquidation, and pays makers + house their collateral in the same fill.
contract BackstopHookTest is Test, Deployers {
    BackstopHook hook;
    V4Venue venue;
    PoolKey hookKey;
    PoolKey vanillaKey;
    RoundFeed feed;
    AutolysisAquaRouter router;
    MakerFactory factory;
    address maker = address(0xAABB);
    address hookOwner = address(0xF00D);

    uint160 constant FLAGS =
        uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        feed = new RoundFeed(address(this), 1e18); // 1 collateral = 1 USDC

        address hookAddr = address(FLAGS);
        BackstopHook impl = new BackstopHook(manager, hookOwner, IRoundFeed(address(feed)), currency1);
        vm.etch(hookAddr, address(impl).code);
        hook = BackstopHook(hookAddr);

        router = new AutolysisAquaRouter(
            IRoundFeed(address(feed)),
            IERC20Min(Currency.unwrap(currency1)),
            IERC20Min(Currency.unwrap(currency0)),
            hookOwner
        );
        factory = new MakerFactory();
        vm.startPrank(hookOwner);
        router.setHook(hookAddr);
        router.allowTemplate(factory.cloneCodehash(), true);
        hook.setRouter(router);
        vm.stopPrank();

        (hookKey,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(hookAddr), 3000, SQRT_PRICE_1_1);
        (vanillaKey,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        // This test contract plays the market: it owns a V4Venue and drives it like executeLiquidation.
        venue = new V4Venue(manager, address(this), currency0, currency1, true);
        venue.setKey(hookKey);
        vm.prank(hookOwner);
        hook.setVenue(address(venue), true);
    }

    function _liq() internal pure returns (bytes memory) {
        return abi.encode(BackstopHook.HookData({isLiquidation: true}));
    }

    function _sell(uint256 amt, uint256 minOut) internal returns (uint256) {
        MockERC20(Currency.unwrap(currency0)).transfer(address(venue), amt); // settle-before-swap
        return venue.sellCollateral(amt, minOut);
    }

    function _directSwap(PoolKey memory key, bytes memory hd) internal returns (BalanceDelta) {
        return swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: 4295128740}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hd
        );
    }

    function _fundDeposits(uint256 amt) internal {
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));
        t1.mint(hookOwner, amt);
        vm.startPrank(hookOwner);
        t1.approve(address(hook), type(uint256).max);
        hook.deposit(currency1, amt);
        vm.stopPrank();
    }

    function _addMaker(uint256 fund, uint256 maxSize) internal {
        address m = factory.create(IERC20Min(Currency.unwrap(currency1)), maker, address(router), maxSize);
        MockERC20(Currency.unwrap(currency1)).mint(maker, fund);
        vm.prank(maker);
        MockERC20(Currency.unwrap(currency1)).approve(m, type(uint256).max);
        vm.prank(hookOwner);
        router.registerMaker(IMakerStrategy(m), 0);
    }

    function _colId() internal view returns (uint256) {
        return uint256(uint160(Currency.unwrap(currency0)));
    }

    // C3: an outside swapper passing liquidation hookData is NOT a registered venue -> vanilla path.
    function test_forgedHookDataGetsVanillaPath() public {
        _fundDeposits(10e18);
        BalanceDelta h = _directSwap(hookKey, _liq());
        BalanceDelta v = _directSwap(vanillaKey, "");
        assertEq(h.amount1(), v.amount1(), "forged liquidation must not fill from the hook");
        assertEq(hook.depositsOf(currency1), 10e18, "deposits must be untouched by a forged swap");
    }

    function test_outsideSwapperMatchesVanilla() public {
        BalanceDelta h = _directSwap(hookKey, "");
        BalanceDelta v = _directSwap(vanillaKey, "");
        assertEq(h.amount1(), v.amount1());
    }

    // C4: a registered venue's liquidation fills from deposits; the house (owner) is paid collateral
    // claims and the hook holds no collateral claims afterward.
    function test_depositsFillPaysHouseAndLeavesNoClaims() public {
        _fundDeposits(10e18);
        uint256 ownerClaimsBefore = manager.balanceOf(hookOwner, _colId());
        uint256 got = _sell(1e15, 1e15); // 1:1 oracle
        assertEq(got, 1e15, "venue should raise 1e15 USDC from the deposits tier");
        assertEq(manager.balanceOf(hookOwner, _colId()) - ownerClaimsBefore, 1e15, "house not paid collateral");
        assertEq(manager.balanceOf(address(hook), _colId()), 0, "hook must hold no collateral claims");
    }

    // C4: a maker fill moves USDC from the maker wallet and pays the maker collateral claims.
    function test_makerFillPaysMakerCollateral() public {
        _addMaker(1e15, 1e15);
        uint256 makerUsdcBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(maker);
        uint256 makerClaimsBefore = manager.balanceOf(maker, _colId());
        _sell(1e15, 1e15);
        assertEq(
            makerUsdcBefore - MockERC20(Currency.unwrap(currency1)).balanceOf(maker), 1e15, "maker USDC not pulled"
        );
        assertEq(manager.balanceOf(maker, _colId()) - makerClaimsBefore, 1e15, "maker not paid collateral");
        assertEq(manager.balanceOf(address(hook), _colId()), 0, "hook must hold no collateral claims");
    }

    // Waterfall order: makers (tier 1) before deposits (tier 2); remainder to the curve (tier 3).
    function test_waterfallOrder() public {
        _addMaker(0.4e15, 0.4e15);
        _fundDeposits(0.4e15);
        uint256 makerClaimsBefore = manager.balanceOf(maker, _colId());
        uint256 ownerClaimsBefore = manager.balanceOf(hookOwner, _colId());
        _sell(1e15, 0); // 0.4 makers + 0.4 deposits + 0.2 curve
        assertEq(manager.balanceOf(maker, _colId()) - makerClaimsBefore, 0.4e15, "tier 1 maker share");
        assertEq(manager.balanceOf(hookOwner, _colId()) - ownerClaimsBefore, 0.4e15, "tier 2 house share");
        assertEq(manager.balanceOf(address(hook), _colId()), 0, "hook holds no claims");
    }

    function test_tier2UntouchedWhenMakersCover() public {
        _addMaker(2e15, 2e15);
        _fundDeposits(10e18);
        uint256 ownerClaimsBefore = manager.balanceOf(hookOwner, _colId());
        _sell(1e15, 1e15);
        assertEq(manager.balanceOf(hookOwner, _colId()), ownerClaimsBefore, "deposits tier must stay untouched");
    }

    // Deltas net to zero for every backstop sale (the unlock reverts otherwise).
    function testFuzz_deltasNetToZero(uint96 amt, bool withMaker) public {
        uint256 a = bound(uint256(amt), 1e9, 1e17);
        _fundDeposits(1e18);
        if (withMaker) _addMaker(1e17, 1e17);
        MockERC20(Currency.unwrap(currency0)).mint(address(this), a);
        _sell(a, 0);
        assertEq(manager.balanceOf(address(hook), _colId()), 0, "hook holds no claims after fill");
    }
}
