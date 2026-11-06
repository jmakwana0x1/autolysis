// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AutolysisMarket} from "../../src/core/AutolysisMarket.sol";
import {AutolysisAccount} from "../../src/core/AutolysisAccount.sol";
import {RoundFeed} from "../../src/core/RoundFeed.sol";
import {BackstopHook, IAquaBalances} from "../../src/backstop/BackstopHook.sol";
import {V4Venue} from "../../src/backstop/V4Venue.sol";
import {ISwapVMRouter} from "../../src/interfaces/ISwapVMRouter.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {IRoundFeed} from "../../src/interfaces/IRoundFeed.sol";
import {ISwapVenue} from "../../src/interfaces/ISwapVenue.sol";
import {FirewallRules} from "../../src/libraries/FirewallRules.sol";
import {TxView, FrameView, FrameTypes} from "../../src/frame/FrameTypes.sol";
import {ProbeConstants} from "../../src/generated/ProbeConstants.sol";
import {MockFrameEnv} from "../mocks/MockFrameEnv.sol";

interface IAquaShip is IAquaBalances {
    function ship(address app, bytes calldata strategy, address[] calldata tokens, uint256[] calldata amounts)
        external
        returns (bytes32);
}

/// ABI of aqua-fork/test/helpers/OrderBuilder.sol (0.8.30; real SwapVM encoders).
interface IOrderBuilder {
    function gatedOracleProgram(address pricer, address priceSource, address collateral, uint64 salt)
        external
        pure
        returns (bytes memory);
    function aquaOrder(address maker, address tokenA, address tokenB, bytes calldata program)
        external
        pure
        returns (ISwapVMRouter.Order memory);
    function exactInTaker(bool isAToB) external pure returns (bytes memory);
}

/// C1 (PLAN-v4.4), local test: one full self-paid liquidation, market -> V4Venue -> v4 pool ->
/// BackstopHook tier 1 -> the REAL gated SwapVM router (aqua-fork, solc 0.8.30, deployed from its
/// artifacts) -> REAL Aqua. The maker ships [LiquidationGate][Extruction -> LiquidationPricer(venue)][Salt]
/// holding USDC; the hook fills as taker at the cited-round price. Exit: maker wallet USDC down and
/// WETH (collateral) up; a stranger's fill reverts LiquidationGateClosed.
/// Needs `just aqua-build` first (`just test` does it). C2 (test/fork/C2_OfficialAqua.t.sol) runs the same
/// flow on a Unichain fork against the official Aqua registry.
abstract contract SwapVMTier1Base is Test, Deployers {
    uint160 constant FLAGS =
        uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
    bytes4 constant GATE_CLOSED = bytes4(keccak256("LiquidationGateClosed()"));
    uint256 constant MAKER_USDC = 1_000e18;

    BackstopHook hook;
    V4Venue venue;
    AutolysisMarket market;
    AutolysisAccount account;
    RoundFeed feed;
    MockFrameEnv env;
    MockERC20 col; // currency0, the WETH stand-in
    MockERC20 usdc; // currency1
    IAquaShip aqua;
    ISwapVMRouter swapVM;
    IOrderBuilder builder;
    address pricer;
    ISwapVMRouter.Order order;
    bytes takerData;
    bytes32 orderHash;

    address borrower = address(0xB0B);
    address maker = address(0xAABB);
    address hookOwner = address(0xF00D);
    address stranger = address(0x5757);
    uint256 posId;

    /// Which Aqua to fill through. C1: a fresh one from the aqua-fork artifacts. C2: the official one.
    function _aqua() internal virtual returns (address);

    /// Runs before anything is deployed (C2 selects the fork here).
    function _beforeSetUp() internal virtual {}

    function setUp() public {
        _beforeSetUp();
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        col = MockERC20(Currency.unwrap(currency0));
        usdc = MockERC20(Currency.unwrap(currency1));
        feed = new RoundFeed(address(this), 2e18); // 1 COL = 2 USDC

        address hookAddr = address(FLAGS);
        BackstopHook impl = new BackstopHook(manager, hookOwner, IRoundFeed(address(feed)), currency1);
        vm.etch(hookAddr, address(impl).code);
        hook = BackstopHook(hookAddr);

        env = new MockFrameEnv();
        account = new AutolysisAccount(env);
        market = new AutolysisMarket(
            IERC20(address(col)), IERC20(address(usdc)), IRoundFeed(address(feed)), address(account)
        );
        account.initialize(market, 0.01e18);

        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(hookAddr), 3000, SQRT_PRICE_1_1);
        venue = new V4Venue(manager, address(market), currency0, currency1, true);
        venue.setKey(key);
        vm.prank(hookOwner);
        hook.setVenue(address(venue), true);
        market.setVenue(ISwapVenue(address(venue)));

        // The 1inch side, from the aqua-profile artifacts (solc 0.8.30, via-IR).
        aqua = IAquaShip(_aqua());
        pricer = vm.deployCode("out-aqua/LiquidationPricer.sol/LiquidationPricer.json");
        builder = IOrderBuilder(vm.deployCode("out-aqua/OrderBuilder.sol/OrderBuilder.json"));
        swapVM = ISwapVMRouter(
            vm.deployCode(
                "out-aqua/AutolysisAquaRouterGated.sol/AutolysisAquaRouterGated.json",
                abi.encode(address(aqua), address(0), hookOwner, "Autolysis", "1", hookAddr, address(venue))
            )
        );

        // Maker ships the gated oracle-priced strategy holding USDC (and 0 collateral) in their wallet.
        assertLt(uint160(address(col)), uint160(address(usdc)), "collateral is tokenA");
        bytes memory program = builder.gatedOracleProgram(pricer, address(venue), address(col), 42);
        order = builder.aquaOrder(maker, address(col), address(usdc), program);
        takerData = builder.exactInTaker(true); // tokenIn = tokenA = collateral
        usdc.mint(maker, MAKER_USDC);
        address[] memory tokens = new address[](2);
        tokens[0] = address(col);
        tokens[1] = address(usdc);
        uint256[] memory amounts = new uint256[](2);
        amounts[1] = MAKER_USDC;
        vm.startPrank(maker);
        usdc.approve(address(aqua), type(uint256).max);
        aqua.ship(address(swapVM), abi.encode(order), tokens, amounts);
        vm.stopPrank();
        orderHash = swapVM.hash(order);

        vm.startPrank(hookOwner);
        hook.setSwapVM(swapVM, aqua);
        hook.addSwapVMOrder(order, takerData);
        vm.stopPrank();

        // Market can lend USDC. Borrower: 100 COL @2 = 200, borrow 150 -> HF 1.0667.
        usdc.mint(address(market), 1_000e18);
        vm.startPrank(borrower);
        posId = market.open();
        col.mint(borrower, 100e18);
        col.approve(address(market), type(uint256).max);
        market.deposit(posId, 100e18);
        market.borrow(posId, 150e18);
        vm.stopPrank();

        // A stranger holds collateral and approves the router, ready to try a direct fill.
        col.mint(stranger, 10e18);
        vm.prank(stranger);
        col.approve(address(swapVM), type(uint256).max);
    }

    function _tx(uint256 roundId) internal view returns (TxView memory v) {
        v.sender = address(account);
        v.nonceKeys = new uint256[](1);
        v.nonceKeys[0] = FirewallRules.nonceKey(address(market), posId);
        v.feeParam = 0; // no gas fee billed here (currency0 is not WETH); the H2 fee path has its own test
        v.frames = new FrameView[](2);
        v.frames[0] = FrameView(
            FrameTypes.MODE_VERIFY,
            address(account),
            99_900,
            ProbeConstants.FIRST_USE_KEY_STATE_GAS + 50_000,
            0,
            FrameTypes.SCOPE_EXECUTION_AND_PAYMENT,
            abi.encodeWithSelector(FirewallRules.VERIFY_SEL)
        );
        v.frames[1] = FrameView(
            FrameTypes.MODE_SENDER,
            address(account),
            1_500_000,
            0,
            0,
            FrameTypes.SCOPE_NONE,
            abi.encodeWithSelector(FirewallRules.EXECUTE_SEL, posId, roundId)
        );
    }

    function _usdcInAqua() internal view returns (uint256 b) {
        (uint248 x,) = aqua.rawBalances(maker, address(swapVM), orderHash, address(usdc));
        b = x;
    }

    function test_tier1FillsThroughGatedSwapVM() public {
        feed.post(1.8e18);
        feed.post(1.62e18); // HF ~0.864
        uint256 roundId = feed.latestRound();
        assertLt(market.healthFactor(posId), 1e18, "unhealthy after crash");

        uint256 makerUsdc0 = usdc.balanceOf(maker);
        uint256 makerCol0 = col.balanceOf(maker);
        uint256 aquaUsdc0 = _usdcInAqua();
        (,, uint256 debt0,) = market.positions(posId);

        env.set(_tx(roundId));
        vm.prank(address(account));
        account.verifyLiquidation();
        vm.recordLogs();
        vm.prank(address(account));
        account.selfLiquidate(posId, roundId);

        // The liquidation went through, and tier 1 (the real SwapVM fill) carried it.
        (,, uint256 debt1,) = market.positions(posId);
        assertLt(debt1, debt0, "debt reduced");
        assertEq(market.liquidationCount(posId), 1, "one step recorded");
        (uint256 filledCol, uint256 filledUsdc, uint256 t1, uint256 t3) = _parseLogs();
        assertGt(filledCol, 0, "SwapVMFilled emitted");
        assertEq(t1, filledUsdc, "tier-1 USDC is the SwapVM fill");
        assertEq(t3, 0, "makers covered the whole sale: tier 3 untouched");

        // Maker wallet: USDC down, collateral (WETH) up, by exactly the fill, at the cited price.
        uint256 makerUsdcDown = makerUsdc0 - usdc.balanceOf(maker);
        uint256 makerColUp = col.balanceOf(maker) - makerCol0;
        assertEq(makerUsdcDown, filledUsdc, "maker USDC down by the fill");
        assertEq(makerColUp, filledCol, "maker WETH up by the fill");
        assertEq(filledUsdc, filledCol * 1.62e18 / 1e18, "priced at the cited round");
        assertEq(aquaUsdc0 - _usdcInAqua(), makerUsdcDown, "Aqua accounting matches the wallet");

        // The hook keeps nothing: no tokens, no ERC-6909 claims, no allowance to the router.
        assertEq(col.balanceOf(address(hook)), 0, "hook holds no collateral");
        assertEq(usdc.balanceOf(address(hook)), 0, "hook holds no USDC");
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(col)))), 0, "no collateral claims");
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(usdc)))), 0, "no USDC claims");
        assertEq(col.allowance(address(hook), address(swapVM)), 0, "no lingering allowance");
    }

    function test_strangerFillRevertsGateClosed() public {
        vm.prank(stranger);
        vm.expectRevert(GATE_CLOSED);
        swapVM.swap(order, 1e18, takerData);
    }

    /// Even the hook cannot fill outside a liquidation: the gate also requires venue.liquidationActive().
    function test_hookOutsideLiquidationRevertsGateClosed() public {
        col.mint(address(hook), 1e18);
        vm.prank(address(hook));
        col.approve(address(swapVM), 1e18);
        vm.prank(address(hook));
        vm.expectRevert(GATE_CLOSED);
        swapVM.swap(order, 1e18, takerData);
    }

    function _parseLogs() internal returns (uint256 filledCol, uint256 filledUsdc, uint256 t1, uint256 t3) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 filledSig = keccak256("SwapVMFilled(uint256,address,uint256,uint256)");
        bytes32 waterfallSig = keccak256("Waterfall(address,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics[0] == filledSig) {
                (uint256 c, uint256 u) = abi.decode(logs[i].data, (uint256, uint256));
                filledCol += c;
                filledUsdc += u;
            } else if (logs[i].topics[0] == waterfallSig) {
                (t1,, t3) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
        }
    }
}

/// C1, local test: a fresh Aqua deployed from the aqua-fork artifacts.
contract C1SwapVMTier1Test is SwapVMTier1Base {
    function _aqua() internal override returns (address) {
        return vm.deployCode("out-aqua/Aqua.sol/Aqua.json");
    }
}
