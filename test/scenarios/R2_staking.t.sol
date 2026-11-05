// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AutolysisMarket} from "../../src/core/AutolysisMarket.sol";
import {AutolysisAccount} from "../../src/core/AutolysisAccount.sol";
import {RoundFeed} from "../../src/core/RoundFeed.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {IRoundFeed} from "../../src/interfaces/IRoundFeed.sol";
import {ISwapVenue} from "../../src/interfaces/ISwapVenue.sol";
import {IStakingRegistry} from "../../src/frame/IStakingRegistry.sol";
import {FirewallRules} from "../../src/libraries/FirewallRules.sol";
import {TxView, FrameView, FrameTypes} from "../../src/frame/FrameTypes.sol";
import {ProbeConstants} from "../../src/generated/ProbeConstants.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MockCurve} from "../mocks/MockCurve.sol";
import {MockFrameEnv} from "../mocks/MockFrameEnv.sol";
import {MockStakingRegistry} from "../mocks/MockStakingRegistry.sol";

/// R2: the account stakes itself in the real registry interface, and VERIFY fits the staked gas limit.
contract R2StakingTest is Test {
    uint256 constant STAKED_VALIDATION_GAS = 1_000_000;

    MockFrameEnv env;
    AutolysisMarket market;
    AutolysisAccount account;
    MockCurve curve;
    RoundFeed feed;
    MockWETH col;
    MockERC20 usdc;
    MockStakingRegistry registry;
    uint256 posId;

    function setUp() public {
        col = new MockWETH();
        vm.deal(address(col), 1_000 ether);
        usdc = new MockERC20("USDC", "USDC", 18);
        feed = new RoundFeed(address(this), 2e18);
        env = new MockFrameEnv();
        account = new AutolysisAccount(env);
        market = new AutolysisMarket(
            IERC20(address(col)), IERC20(address(usdc)), IRoundFeed(address(feed)), address(account)
        );
        account.initialize(market, 0.01e18);
        registry = new MockStakingRegistry();
        account.setStakingRegistry(IStakingRegistry(address(registry)));
        curve = new MockCurve(IERC20(address(col)), IERC20(address(usdc)), IRoundFeed(address(feed)));
        market.setVenue(ISwapVenue(address(curve)));
        usdc.mint(address(market), 1e24);
        usdc.mint(address(curve), 1e24);

        posId = market.open();
        col.mint(address(this), 100e18);
        col.approve(address(market), type(uint256).max);
        market.deposit(posId, 100e18);
        market.borrow(posId, 150e18);
        feed.post(1.8e18);
        feed.post(1.62e18);
    }

    function test_accountStakesItself() public {
        vm.deal(address(this), 2 ether);
        account.stake{value: 1 ether}(86_400);
        (uint256 stake, bool staked, uint32 delay) = registry.getDepositInfo(address(account));
        assertEq(stake, 1 ether, "stake recorded against the account");
        assertTrue(staked, "account should count as staked");
        assertEq(delay, 86_400);
    }

    function test_verifyFitsStakedGasLimit() public {
        uint256 roundId = feed.latestRound();
        TxView memory v;
        v.sender = address(account);
        v.nonceKeys = new uint256[](1);
        v.nonceKeys[0] = FirewallRules.nonceKey(address(market), posId);
        v.sequence = 0;
        v.feeParam = account.feeCapTotal();
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
        env.set(v);

        vm.prank(address(account));
        uint256 g0 = gasleft();
        account.verifyLiquidation();
        uint256 used = g0 - gasleft();
        emit log_named_uint("verifyLiquidation gas", used);
        assertLt(used, STAKED_VALIDATION_GAS, "VERIFY must fit the staked validation-gas limit");
    }
}
