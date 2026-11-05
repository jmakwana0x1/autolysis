// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Aqua} from "@1inch/aqua/contracts/Aqua.sol";
import {TokenMock} from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import {ISwapVM} from "@1inch/swap-vm/contracts/interfaces/ISwapVM.sol";
import {Extruction} from "@1inch/swap-vm/contracts/instructions/Extruction.sol";
import {Salt} from "@1inch/swap-vm/contracts/instructions/Controls.sol";
import {TraitsHelper} from "@1inch/swap-vm/test/solidity/helpers/SwapVMTestSetup.sol";
import {TraitsHelper as TraitsHelperImpl} from "@1inch/swap-vm/test/solidity/helpers/TraitsHelper.sol";
import {AutolysisAquaRouterGated} from "../src/AutolysisAquaRouterGated.sol";
import {LiquidationPricer} from "../src/LiquidationPricer.sol";

contract MockVenue {
    bool public liquidationActive;
    function set(bool v) external { liquidationActive = v; }
}

/// A RoundFeed stand-in: price is debt-token units per 1e18 of collateral, 1e18-scaled.
contract MockPriceSource {
    uint256 public price; // debtPerColl1e18
    constructor(uint256 p) { price = p; }
    function set(uint256 p) external { price = p; }
}

/// W2.2–2.3 (local test): the liquidation tier prices off the oracle, not the pool. A maker ships
/// [gate][Extruction->LiquidationPricer][Salt]; the hook fills and receives exactly amountIn * oracle
/// price, regardless of the shipped reserves — so a reserve-moving sandwich cannot change the fill. The
/// static quote equals the swap (both run the pricer's pure math), so a taker's quote is honored.
contract OraclePricedFillTest is Test {
    Aqua aqua;
    AutolysisAquaRouterGated router;
    LiquidationPricer pricer;
    TraitsHelper orders;
    MockVenue venue;
    MockPriceSource feed;
    TokenMock coll; // collateral (WETH stand-in)
    TokenMock debt; // debt (USDC stand-in)
    bool collIsTokenA; // ship order is (tokenA, tokenB) sorted

    address maker = makeAddr("maker");
    address hook = makeAddr("hook");

    uint256 constant PRICE = 2e18; // 1 collateral = 2 debt

    function setUp() public {
        aqua = new Aqua();
        venue = new MockVenue();
        venue.set(true);
        feed = new MockPriceSource(PRICE);
        pricer = new LiquidationPricer();
        router = new AutolysisAquaRouterGated(address(aqua), address(0), address(this), "Autolysis", "1", hook, address(venue));
        orders = TraitsHelper(address(new TraitsHelperImpl()));

        coll = new TokenMock("WETH", "WETH");
        debt = new TokenMock("USDC", "USDC");
        collIsTokenA = coll < debt;

        // Maker ships both tokens as the oracle-priced liquidity.
        coll.mint(maker, 10_000e18);
        debt.mint(maker, 10_000e18);
        vm.startPrank(maker);
        coll.approve(address(aqua), type(uint256).max);
        debt.approve(address(aqua), type(uint256).max);
        vm.stopPrank();

        // The hook pays collateral in to receive debt out.
        coll.mint(hook, 1_000e18);
        vm.prank(hook);
        coll.approve(address(router), type(uint256).max);
    }

    /// Program: gate, then Extruction into the pricer (args = priceSource ++ collateral), then a Salt.
    function _oracleProgram() internal view returns (bytes memory) {
        bytes memory extArgs = abi.encodePacked(address(feed), address(coll));
        return bytes.concat(hex"f900", Extruction.build(address(pricer), extArgs), Salt.build(42));
    }

    function _shipOrder() internal returns (ISwapVM.Order memory order) {
        (address tokenA, address tokenB) =
            collIsTokenA ? (address(coll), address(debt)) : (address(debt), address(coll));
        order = orders.MakerTraitsLibBuild(TraitsHelper.MakerTraitsLibArgs({
            maker: maker,
            receiver: address(0),
            tokenA: tokenA,
            tokenB: tokenB,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: true,
            usePermit2: false,
            allowZeroAmountIn: false,
            program: _oracleProgram()
        }));
        address[] memory tokens = new address[](2);
        tokens[0] = tokenA;
        tokens[1] = tokenB;
        uint256[] memory amts = new uint256[](2);
        amts[0] = 1_000e18;
        amts[1] = 1_000e18;
        vm.prank(maker);
        aqua.ship(address(router), abi.encode(order), tokens, amts);
    }

    /// isAToB must make tokenIn == collateral so the hook pays collateral and takes debt.
    function _takerData() internal view returns (bytes memory) {
        return orders.TakerTraitsLibBuild(TraitsHelper.TakerTraitsLibArgs({
            taker: address(0),
            isExactIn: true,
            shouldUnwrapWeth: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: true,
            isAToB: collIsTokenA, // tokenIn = tokenA = collateral iff collateral sorts first
            allowPartialFill: true,
            usePermit2: false,
            threshold: "",
            to: address(0),
            hasPreTransferInCallback: false,
            signature: ""
        }));
    }

    function test_fillIsOraclePricedNotReservePriced() public {
        ISwapVM.Order memory order = _shipOrder();
        bytes memory taker = _takerData();
        uint256 amountIn = 10e18;
        uint256 debtBefore = debt.balanceOf(hook);

        vm.prank(hook);
        (uint256 inUsed, uint256 outGot,) = router.swap(order, amountIn, taker);

        assertEq(inUsed, amountIn, "exact-in collateral spent");
        // Oracle rate: 10 collateral * 2 = 20 debt. A constant-product pool over 1000/1000 reserves would
        // have paid ~9.9 debt for 10 in; the oracle price is what the taker gets instead.
        assertEq(outGot, (amountIn * PRICE) / 1e18, "fill equals oracle rate");
        assertEq(debt.balanceOf(hook) - debtBefore, outGot, "hook received debt out");
    }

    function test_quoteEqualsSwap() public {
        ISwapVM.Order memory order = _shipOrder();
        bytes memory taker = _takerData();
        uint256 amountIn = 7e18;

        vm.prank(hook);
        (uint256 qIn, uint256 qOut,) = router.quote(order, amountIn, taker);
        vm.prank(hook);
        (uint256 sIn, uint256 sOut,) = router.swap(order, amountIn, taker);

        assertEq(qIn, sIn, "quote in == swap in");
        assertEq(qOut, sOut, "quote out == swap out");
        assertEq(sOut, (amountIn * PRICE) / 1e18, "both equal oracle rate");
    }

    /// Price moves after ship: the fill tracks the oracle, proving the rate is not baked into reserves.
    function test_fillTracksOraclePriceChange() public {
        ISwapVM.Order memory order = _shipOrder();
        bytes memory taker = _takerData();
        feed.set(3e18); // oracle now 1 collateral = 3 debt

        vm.prank(hook);
        (, uint256 outGot,) = router.swap(order, 10e18, taker);
        assertEq(outGot, 30e18, "fill follows the new oracle price");
    }
}
