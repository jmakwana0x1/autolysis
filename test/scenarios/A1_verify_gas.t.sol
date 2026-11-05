// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AutolysisMarket} from "../../src/core/AutolysisMarket.sol";
import {AutolysisAccount} from "../../src/core/AutolysisAccount.sol";
import {RoundFeed} from "../../src/core/RoundFeed.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {IRoundFeed} from "../../src/interfaces/IRoundFeed.sol";
import {ISwapVenue} from "../../src/interfaces/ISwapVenue.sol";
import {FirewallRules} from "../../src/libraries/FirewallRules.sol";
import {TxView, FrameView, FrameTypes} from "../../src/frame/FrameTypes.sol";
import {ProbeConstants} from "../../src/generated/ProbeConstants.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MockCurve} from "../mocks/MockCurve.sol";
import {MockFrameEnv} from "../mocks/MockFrameEnv.sol";
import {VerifyGas} from "../mocks/VerifyGas.sol";

/// A1 (PLAN-v4.4): VERIFY gas for BOTH paths on the slimmed `loadCanonical()`, measured the same way.
/// Label: MOCK ONLY. The devnet number is `frames[0].gasUsed` from ethrex_simulateFrameTransaction (A4).
/// Method: `VerifyGas.coolAll` (everything VERIFY touches starts cold except the account address).
contract A1VerifyGasTest is Test {
    uint256 constant VERIFY_EXEC_LIMIT_CAP = 100_000 - 100; // MAX_VERIFY_GAS - ARBITRARY signature

    MockFrameEnv env;
    AutolysisMarket market;
    AutolysisAccount account;
    MockCurve curve;
    RoundFeed feed;
    MockWETH col;
    MockERC20 usdc;
    uint256 posId;
    uint256 roundId;

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
        roundId = feed.latestRound();
        env.set(_tx());
    }

    function _tx() internal view returns (TxView memory v) {
        v.sender = address(account);
        v.nonceKeys = new uint256[](1);
        v.nonceKeys[0] = FirewallRules.nonceKey(address(market), posId);
        v.sequence = 0;
        v.feeParam = account.feeCapTotal();
        v.frames = new FrameView[](2);
        v.frames[0] = FrameView(
            FrameTypes.MODE_VERIFY,
            address(account),
            VERIFY_EXEC_LIMIT_CAP,
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

    function _coolAll() internal {
        address[] memory o = new address[](4);
        o[0] = address(market);
        o[1] = address(feed);
        o[2] = address(col);
        o[3] = address(usdc);
        VerifyGas.coolAll(address(env), address(account), o);
    }

    function _measure() internal returns (uint256 used) {
        _coolAll();
        vm.prank(address(account));
        uint256 g0 = gasleft();
        account.verifyLiquidation();
        used = g0 - gasleft();
        assertTrue(env.isApproved(address(account)), "VERIFY must approve");
    }

    function test_gas_outsideReads() public {
        uint256 used = _measure();
        emit log_named_uint("MOCK outside-reads VERIFY gas", used);
        assertLe(used, VERIFY_EXEC_LIMIT_CAP, "outside-reads must fit 99,900 on the mock");
    }

    function test_gas_storageOnly() public {
        account.setStorageOnlyVerify(true);
        account.pushVerifySnapshot(posId, roundId);
        uint256 used = _measure();
        emit log_named_uint("MOCK storage-only VERIFY gas", used);
        assertLe(used, VERIFY_EXEC_LIMIT_CAP, "storage-only must fit 99,900 on the mock");
    }
}
