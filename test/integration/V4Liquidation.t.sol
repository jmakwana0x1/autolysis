// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AutolysisMarket} from "../../src/core/AutolysisMarket.sol";
import {AutolysisAccount} from "../../src/core/AutolysisAccount.sol";
import {RoundFeed} from "../../src/core/RoundFeed.sol";
import {BackstopHook} from "../../src/backstop/BackstopHook.sol";
import {V4Venue} from "../../src/backstop/V4Venue.sol";
import {AutolysisAquaRouter} from "../../src/aqua/AutolysisAquaRouter.sol";
import {MakerFactory} from "../../src/aqua/MakerFactory.sol";
import {IMakerStrategy} from "../../src/aqua/IMakerStrategy.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {IERC20Min} from "../../src/interfaces/IERC20Min.sol";
import {IRoundFeed} from "../../src/interfaces/IRoundFeed.sol";
import {ISwapVenue} from "../../src/interfaces/ISwapVenue.sol";
import {FirewallRules} from "../../src/libraries/FirewallRules.sol";
import {TxView, FrameView, FrameTypes} from "../../src/frame/FrameTypes.sol";
import {ProbeConstants} from "../../src/generated/ProbeConstants.sol";
import {MockFrameEnv} from "../mocks/MockFrameEnv.sol";

/// @notice H4: a full self-paid liquidation driven market -> V4Venue -> real v4 pool + BackstopHook +
///         AquaRouter. Proves the market actually sells through the backstop (not just the unit mocks).
contract V4LiquidationTest is Test, Deployers {
    BackstopHook hook;
    V4Venue venue;
    AutolysisMarket market;
    AutolysisAccount account;
    AutolysisAquaRouter router;
    MakerFactory factory;
    RoundFeed feed;
    MockFrameEnv env;
    MockERC20 col;
    MockERC20 usdc;
    address borrower = address(0xB0B);
    address maker = address(0xAABB);
    address hookOwner = address(0xF00D);
    uint256 posId;

    uint160 constant FLAGS =
        uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);

    function setUp() public {
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

        router = new AutolysisAquaRouter(
            IRoundFeed(address(feed)), IERC20Min(address(usdc)), IERC20Min(address(col)), hookOwner
        );
        factory = new MakerFactory();
        vm.startPrank(hookOwner);
        router.setHook(hookAddr);
        router.allowTemplate(factory.cloneCodehash(), true);
        hook.setRouter(router);
        vm.stopPrank();

        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(hookAddr), 3000, SQRT_PRICE_1_1);

        venue = new V4Venue(manager, address(market), currency0, currency1, true);
        venue.setKey(key);
        vm.prank(hookOwner);
        hook.setVenue(address(venue), true);
        market.setVenue(ISwapVenue(address(venue)));

        // Market can lend USDC; a maker backstops with USDC.
        usdc.mint(address(market), 1_000e18);
        _addMaker(1_000e18);

        // Borrower: 100 COL @2 = 200, borrow 150 -> HF = 100*2*0.8/150 = 1.0667.
        vm.startPrank(borrower);
        posId = market.open();
        col.mint(borrower, 100e18);
        col.approve(address(market), type(uint256).max);
        market.deposit(posId, 100e18);
        market.borrow(posId, 150e18);
        usdc.mint(borrower, 10e18);
        usdc.approve(address(market), type(uint256).max);
        vm.stopPrank();
    }

    function _addMaker(uint256 fund) internal {
        address m = factory.create(IERC20Min(address(usdc)), maker, address(router), type(uint256).max);
        usdc.mint(maker, fund);
        vm.prank(maker);
        usdc.approve(m, type(uint256).max);
        vm.prank(hookOwner);
        router.registerMaker(IMakerStrategy(m), 0);
    }

    function _tx(uint256 roundId, uint256 seq) internal view returns (TxView memory v) {
        v.sender = address(account);
        v.nonceKeys = new uint256[](1);
        v.nonceKeys[0] = FirewallRules.nonceKey(address(market), posId);
        v.sequence = seq;
        v.feeParam = 0; // no gas fee billed here (currency0 is not WETH); H2 fee path has its own test
        v.frames = new FrameView[](2);
        v.frames[0] = FrameView(
            FrameTypes.MODE_VERIFY,
            address(account),
            200_000,
            ProbeConstants.FIRST_USE_KEY_STATE_GAS + 50_000,
            0,
            FrameTypes.SCOPE_EXECUTION_AND_PAYMENT,
            abi.encodeWithSelector(FirewallRules.VERIFY_SEL)
        );
        v.frames[1] = FrameView(
            FrameTypes.MODE_SENDER,
            address(account),
            300_000,
            0,
            0,
            FrameTypes.SCOPE_NONE,
            abi.encodeWithSelector(FirewallRules.EXECUTE_SEL, posId, roundId)
        );
    }

    function test_liquidationThroughV4BackstopFillsFromMaker() public {
        // Gradual in-band crash: 2.0 -> 1.8 -> 1.62, HF ~0.864.
        feed.post(1.8e18);
        feed.post(1.62e18);
        uint256 roundId = feed.latestRound();
        assertLt(market.healthFactor(posId), 1e18, "unhealthy after crash");

        uint256 colId = uint256(uint160(address(col)));
        uint256 makerClaimsBefore = manager.balanceOf(maker, colId);
        uint256 makerUsdcBefore = usdc.balanceOf(maker);
        (,, uint256 debtBefore,) = market.positions(posId);

        env.set(_tx(roundId, 0));
        vm.prank(address(account));
        account.verify();
        vm.prank(address(account));
        account.execute(posId, roundId);

        (,, uint256 debtAfter,) = market.positions(posId);
        assertLt(debtAfter, debtBefore, "debt not reduced through the v4 backstop");
        assertEq(market.liquidationCount(posId), 1, "one step recorded");
        // The maker funded the fill with USDC and received collateral claims in the same liquidation.
        assertLt(usdc.balanceOf(maker), makerUsdcBefore, "maker USDC not used");
        assertGt(manager.balanceOf(maker, colId), makerClaimsBefore, "maker not paid collateral");
        assertEq(manager.balanceOf(address(hook), colId), 0, "hook left holding collateral claims");
    }
}
