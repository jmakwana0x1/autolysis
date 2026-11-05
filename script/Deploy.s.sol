// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {RoundFeed} from "../src/core/RoundFeed.sol";
import {AutolysisAccount} from "../src/core/AutolysisAccount.sol";
import {IStakingRegistry} from "../src/frame/IStakingRegistry.sol";
import {AutolysisMarket} from "../src/core/AutolysisMarket.sol";
import {IFrameEnv} from "../src/frame/IFrameEnv.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IRoundFeed} from "../src/interfaces/IRoundFeed.sol";
import {ISwapVenue} from "../src/interfaces/ISwapVenue.sol";
import {BackstopHook} from "../src/backstop/BackstopHook.sol";
import {V4Venue} from "../src/backstop/V4Venue.sol";
import {AutolysisAquaRouter} from "../src/aqua/AutolysisAquaRouter.sol";
import {MakerFactory} from "../src/aqua/MakerFactory.sol";
import {IERC20Min} from "../src/interfaces/IERC20Min.sol";
import {MockWETH} from "../test/mocks/MockWETH.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @title Deploy
/// @notice Deploys and wires the whole Autolysis stack and writes every address to
///         `deployments/<chainid>.json`. Frame opcodes are not exercised at deploy time, so this runs
///         to completion on a plain anvil (frame features off); on the devnet it is the same script.
///         The Hegota frame env is deployed by artifact name (vm.deployCode) because it compiles at
///         solc 0.8.28 while this script and v4-core are 0.8.26 — importing it would clash.
contract Deploy is Script {
    uint160 constant HOOK_FLAGS =
        uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    struct Addrs {
        address weth;
        address usdc;
        address feed;
        address frameEnv;
        address account;
        address market;
        address manager;
        address hook;
        address venue;
        address router;
        address factory;
        address liquidityRouter;
        address stakingRegistry;
    }

    Addrs internal A;

    function run() external returns (Addrs memory) {
        vm.startBroadcast();
        _deployCore();
        _deployV4();
        _deployAqua();
        _initPoolAndSeed();
        vm.stopBroadcast();
        _writeJson(A);
        return A;
    }

    /// Tokens, feed, frame env, account, market.
    function _deployCore() internal {
        A.weth = address(new MockWETH());
        A.usdc = address(new MockERC20("USD Coin", "USDC", 18));
        A.feed = address(new RoundFeed(msg.sender, 2e18)); // 1 WETH = 2 USDC
        A.frameEnv = deployCode("HegotaFrameEnv.sol:HegotaFrameEnv");
        A.account = address(new AutolysisAccount(IFrameEnv(A.frameEnv)));
        A.market = address(new AutolysisMarket(IERC20(A.weth), IERC20(A.usdc), IRoundFeed(A.feed), A.account));
        AutolysisAccount(payable(A.account)).initialize(AutolysisMarket(payable(A.market)), 0.02e18);
        // Stake the account where a registry is configured (devnet). Set STAKING_REGISTRY and
        // STAKE_VALUE_WEI; on a local anvil both are unset and staking is skipped.
        address registry = vm.envOr("STAKING_REGISTRY", address(0));
        if (registry != address(0)) {
            A.stakingRegistry = registry;
            AutolysisAccount(payable(A.account)).setStakingRegistry(IStakingRegistry(registry));
            AutolysisAccount(payable(A.account)).stake{value: vm.envOr("STAKE_VALUE_WEI", uint256(1 ether))}(86_400);
        }
    }

    /// Pool manager, mined-address hook, venue.
    function _deployV4() internal {
        A.manager = address(new PoolManager(msg.sender));
        (bytes32 salt,) = _mineHook(A.manager, msg.sender, A.feed, Currency.wrap(A.usdc));
        BackstopHook hook = new BackstopHook{salt: salt}(
            IPoolManager(A.manager), msg.sender, IRoundFeed(A.feed), Currency.wrap(A.usdc)
        );
        require(uint160(address(hook)) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS, "hook flags");
        A.hook = address(hook);
        (,, bool wethIsZero) = _sortedCurrencies(A.weth, A.usdc);
        A.venue = address(
            new V4Venue(IPoolManager(A.manager), A.market, Currency.wrap(A.weth), Currency.wrap(A.usdc), wethIsZero)
        );
        hook.setVenue(A.venue, true);
        AutolysisMarket(payable(A.market)).setVenue(ISwapVenue(A.venue));
    }

    /// Aqua model router (replaced by the gated SwapVM fork once R5 is wired on the devnet).
    function _deployAqua() internal {
        AutolysisAquaRouter router =
            new AutolysisAquaRouter(IRoundFeed(A.feed), IERC20Min(A.usdc), IERC20Min(A.weth), msg.sender);
        MakerFactory factory = new MakerFactory();
        router.setHook(A.hook);
        router.allowTemplate(factory.cloneCodehash(), true);
        BackstopHook(A.hook).setRouter(router);
        A.router = address(router);
        A.factory = address(factory);
    }

    function _initPoolAndSeed() internal {
        (Currency c0, Currency c1,) = _sortedCurrencies(A.weth, A.usdc);
        PoolKey memory key = PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(A.hook)});
        V4Venue(A.venue).setKey(key);
        PoolManager(A.manager).initialize(key, SQRT_PRICE_1_1);
        A.liquidityRouter = _seedLiquidity(PoolManager(A.manager), key, MockWETH(payable(A.weth)), MockERC20(A.usdc));
    }

    function _seedLiquidity(PoolManager manager, PoolKey memory key, MockWETH weth, MockERC20 usdc)
        internal
        returns (address)
    {
        PoolModifyLiquidityTest liqRouter = new PoolModifyLiquidityTest(manager);
        weth.mint(msg.sender, 1_000e18);
        usdc.mint(msg.sender, 1_000_000e18);
        weth.approve(address(liqRouter), type(uint256).max);
        usdc.approve(address(liqRouter), type(uint256).max);
        liqRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 100e18, salt: 0}), ""
        );
        return address(liqRouter);
    }

    function _mineHook(address manager, address owner, address feed, Currency debt)
        internal
        pure
        returns (bytes32 salt, address predicted)
    {
        bytes memory initcode =
            abi.encodePacked(type(BackstopHook).creationCode, abi.encode(manager, owner, IRoundFeed(feed), debt));
        bytes32 initHash = keccak256(initcode);
        for (uint256 i; i < 300_000; ++i) {
            salt = bytes32(i);
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, initHash)))));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS) return (salt, predicted);
        }
        revert("no hook salt");
    }

    function _sortedCurrencies(address weth, address usdc)
        internal
        pure
        returns (Currency c0, Currency c1, bool wethIsZero)
    {
        if (weth < usdc) return (Currency.wrap(weth), Currency.wrap(usdc), true);
        return (Currency.wrap(usdc), Currency.wrap(weth), false);
    }

    function _writeJson(Addrs memory a) internal {
        string memory o = "deploy";
        vm.serializeAddress(o, "WETH", a.weth);
        vm.serializeAddress(o, "USDC", a.usdc);
        vm.serializeAddress(o, "RoundFeed", a.feed);
        vm.serializeAddress(o, "HegotaFrameEnv", a.frameEnv);
        vm.serializeAddress(o, "AutolysisAccount", a.account);
        vm.serializeAddress(o, "AutolysisMarket", a.market);
        vm.serializeAddress(o, "PoolManager", a.manager);
        vm.serializeAddress(o, "BackstopHook", a.hook);
        vm.serializeAddress(o, "V4Venue", a.venue);
        vm.serializeAddress(o, "AutolysisAquaRouter", a.router);
        vm.serializeAddress(o, "MakerFactory", a.factory);
        vm.serializeAddress(o, "PoolModifyLiquidityTest", a.liquidityRouter);
        string memory json = vm.serializeAddress(o, "StakingRegistry", a.stakingRegistry);
        vm.writeJson(json, string.concat("deployments/", vm.toString(block.chainid), ".json"));
    }
}
