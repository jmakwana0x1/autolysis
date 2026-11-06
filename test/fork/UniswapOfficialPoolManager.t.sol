// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AutolysisMarket} from "../../src/core/AutolysisMarket.sol";
import {AutolysisAccount} from "../../src/core/AutolysisAccount.sol";
import {RoundFeed} from "../../src/core/RoundFeed.sol";
import {BackstopHook} from "../../src/backstop/BackstopHook.sol";
import {V4Venue} from "../../src/backstop/V4Venue.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {IRoundFeed} from "../../src/interfaces/IRoundFeed.sol";
import {ISwapVenue} from "../../src/interfaces/ISwapVenue.sol";
import {FirewallRules} from "../../src/libraries/FirewallRules.sol";
import {TxView, FrameView, FrameTypes} from "../../src/frame/FrameTypes.sol";
import {ProbeConstants} from "../../src/generated/ProbeConstants.sol";
import {MockFrameEnv} from "../mocks/MockFrameEnv.sol";
import {BalanceTable} from "../utils/BalanceTable.sol";
import {UnichainFork} from "./UnichainFork.sol";

/// Uniswap track, ON FORK: a full self-paid Autolysis liquidation through the OFFICIAL Uniswap v4
/// PoolManager on Unichain mainnet (0x1F98…0004), at a pinned block. Our BackstopHook is deployed the
/// production way (CREATE2 with a mined salt so its address carries the permission bits) against the
/// official manager; the pool is initialized there at the oracle's crash price. One liquidation fills from
/// tier 2 (the hook's house deposits, priced at the cited round) and the rest from tier 3 (the official
/// pool's own curve), inside a single PoolManager.unlock. Run: `just fork-uniswap`.
contract UniswapOfficialPoolManagerForkTest is Test, UnichainFork {
    uint160 constant FLAGS =
        uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
    uint160 constant SQRT_PRICE_1_62 = 100840987754615051853717488809; // sqrt(1.62) * 2^96
    uint256 constant HOUSE_USDC = 50e18; // smaller than the sale, so tier 3 (the official curve) fills the rest
    bytes32 constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    BackstopHook hook;
    V4Venue venue;
    AutolysisMarket market;
    AutolysisAccount account;
    RoundFeed feed;
    MockFrameEnv env;
    MockERC20 col; // currency0 (collateral)
    MockERC20 usdc; // currency1 (debt)
    address borrower = address(0xB0B);
    address hookOwner = address(0xF00D);
    uint256 posId;

    function setUp() public {
        if (!_selectUnichainFork()) return;
        _useOfficialManager();
        _officialManagerCurrencies();
        col = MockERC20(Currency.unwrap(currency0));
        usdc = MockERC20(Currency.unwrap(currency1));

        feed = new RoundFeed(address(this), 2e18);
        env = new MockFrameEnv();
        account = new AutolysisAccount(env);
        market = new AutolysisMarket(
            IERC20(address(col)), IERC20(address(usdc)), IRoundFeed(address(feed)), address(account)
        );
        account.initialize(market, 0.01e18);

        // The hook, mined and CREATE2-deployed against the official manager (not etched).
        bytes memory args = abi.encode(manager, hookOwner, IRoundFeed(address(feed)), currency1);
        bytes32 salt = _mineHookSalt(keccak256(abi.encodePacked(type(BackstopHook).creationCode, args)));
        hook = new BackstopHook{salt: salt}(manager, hookOwner, IRoundFeed(address(feed)), currency1);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, FLAGS, "hook address carries the permission bits");

        // Pool on the OFFICIAL manager at the crash price, with deep liquidity around it.
        key = PoolKey({currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(hook))});
        manager.initialize(key, SQRT_PRICE_1_62);
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: 3600, tickUpper: 6000, liquidityDelta: 100_000e18, salt: 0}), ""
        );

        venue = new V4Venue(manager, address(market), currency0, currency1, true);
        venue.setKey(key);
        vm.prank(hookOwner);
        hook.setVenue(address(venue), true);
        market.setVenue(ISwapVenue(address(venue)));

        // House tier: the hook owner deposits USDC (tier 2).
        usdc.transfer(hookOwner, HOUSE_USDC);
        vm.startPrank(hookOwner);
        usdc.approve(address(hook), HOUSE_USDC);
        hook.deposit(currency1, HOUSE_USDC);
        vm.stopPrank();

        // Lending liquidity and one borrower: 100 COL @2, borrow 150 -> HF 1.0667.
        usdc.transfer(address(market), 1_000e18);
        col.transfer(borrower, 100e18);
        vm.startPrank(borrower);
        posId = market.open();
        col.approve(address(market), type(uint256).max);
        market.deposit(posId, 100e18);
        market.borrow(posId, 150e18);
        vm.stopPrank();
    }

    function _mineHookSalt(bytes32 initHash) internal view returns (bytes32 salt) {
        for (uint256 i; i < 1_000_000; ++i) {
            salt = bytes32(i);
            address a = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash)))));
            if (uint160(a) & Hooks.ALL_HOOK_MASK == FLAGS) return salt;
        }
        revert("no hook salt");
    }

    function _tx(uint256 roundId) internal view returns (TxView memory v) {
        v.sender = address(account);
        v.nonceKeys = new uint256[](1);
        v.nonceKeys[0] = FirewallRules.nonceKey(address(market), posId);
        v.feeParam = 0; // gas billing in collateral needs WETH; covered by the H2 tests
        v.frames = new FrameView[](2);
        v.frames[0] = FrameView(FrameTypes.MODE_VERIFY, address(account), 99_900, ProbeConstants.FIRST_USE_KEY_STATE_GAS + 50_000, 0, FrameTypes.SCOPE_EXECUTION_AND_PAYMENT, abi.encodeWithSelector(FirewallRules.VERIFY_SEL));
        v.frames[1] = FrameView(FrameTypes.MODE_SENDER, address(account), 1_500_000, 0, 0, FrameTypes.SCOPE_NONE, abi.encodeWithSelector(FirewallRules.EXECUTE_SEL, posId, roundId));
    }

    struct Snap {
        uint256 posCol;
        uint256 posDebt;
        uint256 hf;
        uint256 pmCol;
        uint256 pmUsdc;
        uint256 hookCol;
        uint256 hookUsdc;
        uint256 hookClaimsCol;
        uint256 hookClaimsUsdc;
        uint256 house;
        uint256 ownerCol;
        uint256 marketUsdc;
    }

    function _snap() internal view returns (Snap memory s) {
        (, s.posCol, s.posDebt,) = market.positions(posId);
        s.hf = market.healthFactor(posId);
        s.pmCol = col.balanceOf(address(manager));
        s.pmUsdc = usdc.balanceOf(address(manager));
        s.hookCol = col.balanceOf(address(hook));
        s.hookUsdc = usdc.balanceOf(address(hook));
        s.hookClaimsCol = manager.balanceOf(address(hook), uint256(uint160(address(col))));
        s.hookClaimsUsdc = manager.balanceOf(address(hook), uint256(uint160(address(usdc))));
        s.house = hook.depositsOf(currency1);
        s.ownerCol = col.balanceOf(hookOwner);
        s.marketUsdc = usdc.balanceOf(address(market));
    }

    function test_liquidationThroughOfficialPoolManager() public {
        feed.post(1.8e18);
        feed.post(1.62e18); // HF ~0.864
        uint256 roundId = feed.latestRound();
        Snap memory b = _snap();
        assertLt(b.hf, 1e18, "unhealthy after the crash");

        env.set(_tx(roundId));
        vm.prank(address(account));
        account.verifyLiquidation();
        vm.recordLogs();
        vm.prank(address(account));
        account.selfLiquidate(posId, roundId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Snap memory a = _snap();

        // The swap happened on the official PoolManager, and the waterfall used tiers 2 and 3.
        (bool swapOnOfficial, uint256 t2, uint256 t3) = _parse(logs);
        assertTrue(swapOnOfficial, "Swap event emitted by the official PoolManager");
        assertGt(t2, 0, "tier 2 (house) filled");
        assertGt(t3, 0, "tier 3 (official pool curve) filled the rest");

        assertEq(market.liquidationCount(posId), 1, "one self-liquidation step");
        assertLt(a.posDebt, b.posDebt, "debt repaid");
        assertGt(a.hf, b.hf, "health factor improved");
        assertEq(a.hookCol, 0, "hook holds no collateral tokens");
        assertEq(a.hookClaimsCol + a.hookClaimsUsdc, 0, "hook holds no ERC-6909 claims");
        assertEq(b.house - a.house, t2, "house deposits paid out exactly tier 2");
        assertGt(a.ownerCol, b.ownerCol, "house received real collateral for its USDC");
        assertGt(a.pmCol, b.pmCol, "the official pool took collateral (tier 3)");
        assertLt(a.pmUsdc, b.pmUsdc, "and paid out USDC (tier 3)");

        BalanceTable.header("Uniswap v4: one self-liquidation through the official PoolManager (Unichain fork)");
        BalanceTable.row("Borrower collateral (COL)", b.posCol, a.posCol);
        BalanceTable.row("Borrower debt (USDC)", b.posDebt, a.posDebt);
        BalanceTable.row("Health factor", b.hf, a.hf);
        BalanceTable.row("Official PoolManager COL", b.pmCol, a.pmCol);
        BalanceTable.row("Official PoolManager USDC", b.pmUsdc, a.pmUsdc);
        BalanceTable.row("Hook COL (tokens)", b.hookCol, a.hookCol);
        BalanceTable.row("Hook ERC-6909 claims (COL + USDC)", b.hookClaimsCol + b.hookClaimsUsdc, a.hookClaimsCol + a.hookClaimsUsdc);
        BalanceTable.row("Hook house deposits (USDC, tier 2)", b.house, a.house);
        BalanceTable.row("House owner COL (paid for tier 2)", b.ownerCol, a.ownerCol);
        BalanceTable.row("Market USDC (repayment in)", b.marketUsdc, a.marketUsdc);
        BalanceTable.note(string.concat("Waterfall: tier 2 = ", BalanceTable.fmt(t2), " USDC, tier 3 = ", BalanceTable.fmt(t3), " COL on the official pool curve"));
    }

    /// Anyone else swapping on the same official pool sees a normal pool: the hook returns ZERO_DELTA.
    function test_outsideSwapperSeesNormalPool() public {
        uint256 house0 = hook.depositsOf(currency1);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 4295128740}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(BackstopHook.HookData({isLiquidation: true})) // claiming a liquidation does not authorize
        );
        assertEq(hook.depositsOf(currency1), house0, "house tier untouched by an outside swapper");
        assertEq(col.balanceOf(address(hook)), 0, "hook untouched");
    }

    function _parse(Vm.Log[] memory logs) internal view returns (bool swapOnOfficial, uint256 t2, uint256 t3) {
        bytes32 wf = keccak256("Waterfall(address,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == OFFICIAL_POOL_MANAGER && logs[i].topics[0] == SWAP_TOPIC) swapOnOfficial = true;
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == wf) {
                (, t2, t3) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
        }
    }
}
