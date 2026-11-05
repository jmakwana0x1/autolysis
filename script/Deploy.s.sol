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

    // Hegota devnet (chain 1337) predeployed Uniswap v4 (real bytecode). See docs/DEVNET.md. With
    // USE_PREDEPLOYED_V4=true the BackstopHook is mined against this PoolManager instead of a fresh one,
    // so the EF and Uniswap proofs run on one chain with official v4 bytecode. Tokens stay as our mocks
    // (the real devnet USDC 0xEFe0...6AF5 is deployer-only mint; WETH9 0x1b7d...87b6 has no premint), so
    // the pool is our WETH/USDC pair on the official manager.
    address constant DEVNET_POOL_MANAGER = 0x6bF9Aa9c04fd001385742d61f6818C3236429848;
    // NaiveStakingRegistry on the devnet; minStake 0.01 ETH, keyed on msg.sender (the account). The
    // owner calls account.stake{value}(86400) as a normal legacy tx. See docs/DEVNET.md.
    address constant DEVNET_STAKING_REGISTRY = 0xD51c04d7A0B01124E84DE152F4e56d9eeCB22D2F;

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
        address probeOpcodes;
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
        A.probeOpcodes = deployCode("ProbeOpcodes.sol:ProbeOpcodes");
        A.account = address(new AutolysisAccount(IFrameEnv(A.frameEnv)));
        A.market = address(new AutolysisMarket(IERC20(A.weth), IERC20(A.usdc), IRoundFeed(A.feed), A.account));
        AutolysisAccount(payable(A.account)).initialize(AutolysisMarket(payable(A.market)), 0.02e18);

        // On the Hegota sidecar, VERIFY has only MAX_VERIFY_GAS = 100,000 (no 1M staked allowance), and
        // the staked-read VERIFY path measures ~131k. So enable the storage-only VERIFY path (W1.5),
        // which reads the round/health gate from the account's own storage and fits under the cap
        // (~98.6k). Off by default (the staked-read path is correct on a full ERC-8421 node); set
        // STORAGE_ONLY_VERIFY=true for the devnet. See docs/DEVNET.md.
        if (vm.envOr("STORAGE_ONLY_VERIFY", false)) {
            AutolysisAccount(payable(A.account)).setStorageOnlyVerify(true);
        }

        // Stake the account so VERIFY reads are admitted and the crash demo can hold >4 pending txs.
        // STAKING_REGISTRY defaults to the devnet NaiveStakingRegistry; STAKE_VALUE_WEI defaults to
        // 0.012 ETH (> minStake 0.01). On a local anvil pass STAKING_REGISTRY=0x0 to skip staking.
        address registry = vm.envOr("STAKING_REGISTRY", DEVNET_STAKING_REGISTRY);
        if (registry != address(0) && registry.code.length > 0) {
            A.stakingRegistry = registry;
            AutolysisAccount(payable(A.account)).setStakingRegistry(IStakingRegistry(registry));
            AutolysisAccount(payable(A.account)).stake{value: vm.envOr("STAKE_VALUE_WEI", uint256(0.012 ether))}(
                86_400
            );
        }
    }

    /// Pool manager, mined-address hook, venue.
    function _deployV4() internal {
        // USE_PREDEPLOYED_V4=true on the devnet: mine the hook against the official PoolManager instead
        // of deploying a fresh one, so the hook runs against real v4 bytecode. Otherwise deploy one
        // (anvil / fork). See docs/DEVNET.md.
        if (vm.envOr("USE_PREDEPLOYED_V4", false)) {
            require(DEVNET_POOL_MANAGER.code.length > 0, "no predeployed PoolManager");
            A.manager = DEVNET_POOL_MANAGER;
        } else {
            A.manager = address(new PoolManager(msg.sender));
        }
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
        vm.serializeAddress(o, "StakingRegistry", a.stakingRegistry);
        string memory json = vm.serializeAddress(o, "ProbeOpcodes", a.probeOpcodes);
        vm.writeJson(json, string.concat("deployments/", vm.toString(block.chainid), ".json"));
    }
}
