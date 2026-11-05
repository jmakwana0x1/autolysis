// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AutolysisAquaRouter} from "../../src/aqua/AutolysisAquaRouter.sol";
import {WalletMakerStrategy} from "../../src/aqua/WalletMakerStrategy.sol";
import {MakerFactory} from "../../src/aqua/MakerFactory.sol";
import {AquaPricing} from "../../src/aqua/AquaPricing.sol";
import {IMakerStrategy} from "../../src/aqua/IMakerStrategy.sol";
import {IRoundFeed} from "../../src/interfaces/IRoundFeed.sol";
import {IERC20Min} from "../../src/interfaces/IERC20Min.sol";
import {RoundFeed} from "../../src/core/RoundFeed.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {GasBombStrategy, RugStrategy} from "../mocks/BadMakerStrategies.sol";

contract AquaRouterTest is Test {
    AutolysisAquaRouter router;
    RoundFeed feed;
    MockERC20 usdc;
    MockERC20 col;
    address hook = address(0xC0FFEE);
    address makerA = address(0xAA);
    address makerB = address(0xBB);
    MakerFactory factory;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 18);
        col = new MockERC20("COL", "COL", 18);
        feed = new RoundFeed(address(this), 2e18); // 1 COL = 2 USDC
        router = new AutolysisAquaRouter(
            IRoundFeed(address(feed)), IERC20Min(address(usdc)), IERC20Min(address(col)), address(this)
        );
        router.setHook(hook);
        // allowlist the canonical template (the shared clone code hash)
        factory = new MakerFactory();
        router.allowTemplate(factory.cloneCodehash(), true);
    }

    function _addMaker(address wallet, uint256 fund, uint256 maxSize, uint256 spreadBps)
        internal
        returns (uint256 id, WalletMakerStrategy s)
    {
        s = WalletMakerStrategy(factory.create(IERC20Min(address(usdc)), wallet, address(router), maxSize));
        usdc.mint(wallet, fund);
        vm.prank(wallet);
        usdc.approve(address(s), type(uint256).max);
        id = router.registerMaker(IMakerStrategy(address(s)), spreadBps);
    }

    function _openGate() internal {
        vm.prank(hook);
        router.setGate(true);
    }

    // LiquidationGate: no one outside a liquidation (non-hook, or gate closed) can fill.
    function test_outsideTakerReverts() public {
        _addMaker(makerA, 1000e18, 1000e18, 50);
        vm.expectRevert(AutolysisAquaRouter.NotHook.selector);
        router.fill(1e18, address(this), 2e18); // not the hook
    }

    function test_gateClosedReverts() public {
        _addMaker(makerA, 1000e18, 1000e18, 50);
        vm.prank(hook);
        vm.expectRevert(AutolysisAquaRouter.GateClosed.selector);
        router.fill(1e18, address(this), 2e18);
    }

    // Template allowlist: a non-allowlisted strategy cannot be registered.
    function test_nonAllowlistedTemplateRejected() public {
        GasBombStrategy bomb = new GasBombStrategy();
        vm.expectRevert(AutolysisAquaRouter.TemplateNotAllowed.selector);
        router.registerMaker(IMakerStrategy(address(bomb)), 0);
    }

    // A fill moves USDC from a maker's wallet to the recipient.
    function test_fillMovesUsdcFromMakerWallet() public {
        _addMaker(makerA, 1000e18, 1000e18, 0); // no spread; eff price = 2.0
        _openGate();
        uint256 before = usdc.balanceOf(makerA);
        vm.prank(hook);
        (uint256 usdcOut, uint256 colUsed,) = router.fill(10e18, hook, 2e18); // sell 10 COL
        // 10 COL * 2 USDC = 20 USDC expected (capped by maker funds 1000)
        assertEq(usdcOut, 20e18, "usdc raised");
        assertEq(colUsed, 10e18, "collateral used");
        assertEq(usdc.balanceOf(makerA), before - 20e18, "maker wallet not debited");
        assertEq(usdc.balanceOf(hook), 20e18, "recipient not funded");
    }

    // quote() equals the fill under unchanged state.
    function test_quoteEqualsFill() public {
        _addMaker(makerA, 15e18, 15e18, 100); // spread 1% -> eff 1.98
        _addMaker(makerB, 1000e18, 1000e18, 300); // spread 3% -> eff 1.94
        (uint256 qUsdc, uint256 qCol) = router.quote(20e18, 2e18);
        _openGate();
        vm.prank(hook);
        (uint256 fUsdc, uint256 fCol,) = router.fill(20e18, hook, 2e18);
        assertEq(qUsdc, fUsdc, "quote usdc != fill usdc");
        assertEq(qCol, fCol, "quote collateral != fill collateral");
    }

    // A maker emptied / rugged between quote and fill is skipped; the next maker completes the fill.
    function test_ruggedMakerSkipped() public {
        RugStrategy rug = new RugStrategy();
        router.allowTemplate(address(rug).codehash, true);
        router.registerMaker(IMakerStrategy(address(rug)), 0); // maker 0: promises but reverts on commit
        _addMaker(makerB, 1000e18, 1000e18, 0); // maker 1: real funds
        _openGate();
        vm.prank(hook);
        (uint256 usdcOut,,) = router.fill(10e18, hook, 2e18);
        assertEq(usdcOut, 20e18, "next maker should cover after rug");
        assertEq(usdc.balanceOf(hook), 20e18);
    }

    // A gas-bomb maker is cut off by the stipend and skipped; the next maker completes the fill.
    function test_gasBombMakerSkipped() public {
        GasBombStrategy bomb = new GasBombStrategy();
        router.allowTemplate(address(bomb).codehash, true);
        router.registerMaker(IMakerStrategy(address(bomb)), 0); // maker 0: burns gas in available()
        _addMaker(makerB, 1000e18, 1000e18, 0); // maker 1: real funds
        _openGate();
        vm.prank(hook);
        (uint256 usdcOut,,) = router.fill(10e18, hook, 2e18);
        assertEq(usdcOut, 20e18, "gas bomb should be skipped, next maker covers");
    }

    // An emptied maker (wallet drained) is skipped.
    function test_emptyMakerSkipped() public {
        (, WalletMakerStrategy sA) = _addMaker(makerA, 0, 1000e18, 0); // funded with 0
        _addMaker(makerB, 1000e18, 1000e18, 0);
        _openGate();
        vm.prank(hook);
        (uint256 usdcOut,,) = router.fill(10e18, hook, 2e18);
        assertEq(usdcOut, 20e18, "empty maker skipped, next covers");
        sA; // silence unused
    }
}
