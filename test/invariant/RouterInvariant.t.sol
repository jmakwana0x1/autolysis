// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AutolysisAquaRouter} from "../../src/aqua/AutolysisAquaRouter.sol";
import {MakerFactory} from "../../src/aqua/MakerFactory.sol";
import {IMakerStrategy} from "../../src/aqua/IMakerStrategy.sol";
import {RoundFeed} from "../../src/core/RoundFeed.sol";
import {IRoundFeed} from "../../src/interfaces/IRoundFeed.sol";
import {IERC20Min} from "../../src/interfaces/IERC20Min.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// Handler driving the router the way a gated hook + makers would, plus stranger attempts.
contract RouterHandler is Test {
    AutolysisAquaRouter public router;
    MockERC20 public usdc;
    RoundFeed public feed;
    MakerFactory public factory;
    address public hook;

    address[] public wallets;
    uint256 public hookReceived; // total USDC the recipient (hook) got from gated fills
    uint256 public strangerMoved; // must stay zero
    uint256 public initialWalletTotal;

    constructor(AutolysisAquaRouter r, MockERC20 u, RoundFeed f, MakerFactory fac, address h) {
        router = r;
        usdc = u;
        feed = f;
        factory = fac;
        hook = h;
    }

    function addMaker(uint256 fund, uint256 spread) public {
        if (wallets.length >= 8) return;
        fund = bound(fund, 0, 1_000e18);
        spread = bound(spread, 0, 500);
        address w = address(uint160(0xA000 + wallets.length * 7));
        address m = factory.create(IERC20Min(address(usdc)), w, address(router), type(uint256).max);
        usdc.mint(w, fund);
        initialWalletTotal += fund;
        vm.prank(w);
        usdc.approve(m, type(uint256).max);
        router.registerMaker(IMakerStrategy(m), spread);
        wallets.push(w);
    }

    function movePrice(uint256 p) public {
        uint256 cur = feed.getRound(feed.latestRound()).price;
        p = bound(p, cur * 95 / 100, cur * 105 / 100);
        if (p == 0) p = 1;
        feed.post(p);
    }

    function gatedFill(uint256 amt) public {
        amt = bound(amt, 1, 100e18);
        vm.prank(hook);
        router.setGate(true);
        vm.prank(hook);
        try router.fill(amt, hook) returns (uint256 usdcOut, uint256, AutolysisAquaRouter.Payout[] memory) {
            hookReceived += usdcOut;
        } catch {}
        vm.prank(hook);
        router.setGate(false);
    }

    function strangerFill(uint256 amt) public {
        amt = bound(amt, 1, 100e18);
        uint256 before = usdc.balanceOf(address(this));
        try router.fill(amt, address(this)) {
            strangerMoved += usdc.balanceOf(address(this)) - before;
        } catch {}
    }

    function walletCount() external view returns (uint256) {
        return wallets.length;
    }

    function walletBalanceTotal() external view returns (uint256 t) {
        for (uint256 i; i < wallets.length; ++i) {
            t += usdc.balanceOf(wallets[i]);
        }
    }
}

contract RouterInvariantTest is Test {
    RouterHandler handler;
    MockERC20 usdc;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 18);
        RoundFeed feed = new RoundFeed(address(this), 2e18);
        AutolysisAquaRouter router = new AutolysisAquaRouter(
            IRoundFeed(address(feed)), IERC20Min(address(usdc)), IERC20Min(address(usdc)), address(this)
        );
        address hook = address(0xC0FFEE);
        router.setHook(hook);
        MakerFactory factory = new MakerFactory();
        router.allowTemplate(factory.cloneCodehash(), true);
        handler = new RouterHandler(router, usdc, feed, factory, hook);
        feed.transferUpdater(address(handler));

        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](4);
        sel[0] = handler.addMaker.selector;
        sel[1] = handler.movePrice.selector;
        sel[2] = handler.gatedFill.selector;
        sel[3] = handler.strangerFill.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    // A stranger (non-hook) can never move maker funds.
    function invariant_strangerNeverMovesFunds() public view {
        assertEq(handler.strangerMoved(), 0, "stranger moved maker funds");
    }

    // USDC conservation: what left maker wallets equals what the recipient received.
    function invariant_usdcConserved() public view {
        uint256 left = handler.initialWalletTotal() - handler.walletBalanceTotal();
        assertEq(left, handler.hookReceived(), "USDC moved out of wallets != received by recipient");
    }

    // The gate is closed at rest (every fill brackets its own open/close).
    function invariant_gateClosedAtRest() public view {
        assertFalse(AutolysisAquaRouter(address(handler.router())).gateOpen(), "gate left open");
    }
}
