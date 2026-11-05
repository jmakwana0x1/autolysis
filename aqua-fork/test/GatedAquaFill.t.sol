// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Aqua} from "@1inch/aqua/contracts/Aqua.sol";
import {TokenMock} from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import {ISwapVM} from "@1inch/swap-vm/contracts/interfaces/ISwapVM.sol";
import {XYCSwap} from "@1inch/swap-vm/contracts/instructions/XYCSwap.sol";
import {Salt} from "@1inch/swap-vm/contracts/instructions/Controls.sol";
import {TraitsHelper} from "@1inch/swap-vm/test/solidity/helpers/SwapVMTestSetup.sol";
// Concrete helper, aliased: SwapVMTestSetup exposes TraitsHelper only as an interface and the
// SwapVM tests deploy the implementation through DeployCode (vm.getCode). getCode keys on the
// source path, which here lives under lib/, so it can't be found; we deploy the implementation
// with `new` instead. The alias keeps the concrete struct names from clashing with the interface.
import {TraitsHelper as TraitsHelperImpl} from "@1inch/swap-vm/test/solidity/helpers/TraitsHelper.sol";
import {AutolysisAquaRouterGated} from "../src/AutolysisAquaRouterGated.sol";

contract MockVenue {
    bool public liquidationActive;
    function set(bool v) external { liquidationActive = v; }
}

/// W2 exit (local test): a real Aqua fill through our gated SwapVM router. A maker ships a program whose
/// first instruction is the LiquidationGate (0xf9); the hook taker fills (tokens move through Aqua); a
/// stranger taker reverts LiquidationGateClosed.
contract GatedAquaFillTest is Test {
    Aqua aqua;
    AutolysisAquaRouterGated router;
    TraitsHelper orders;
    MockVenue venue;
    TokenMock tokenA; // sorted
    TokenMock tokenB;
    address maker = makeAddr("maker");
    address hook = makeAddr("hook");
    address stranger = makeAddr("stranger");

    function setUp() public {
        aqua = new Aqua();
        venue = new MockVenue();
        venue.set(true);
        router = new AutolysisAquaRouterGated(address(aqua), address(0), address(this), "Autolysis", "1", hook, address(venue));
        orders = TraitsHelper(address(new TraitsHelperImpl()));

        tokenA = new TokenMock("TKA", "TKA");
        tokenB = new TokenMock("TKB", "TKB");
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);

        // Maker ships both tokens into Aqua against the gated program.
        tokenA.mint(maker, 10_000e18);
        tokenB.mint(maker, 10_000e18);
        vm.startPrank(maker);
        tokenA.approve(address(aqua), type(uint256).max);
        tokenB.approve(address(aqua), type(uint256).max);
        vm.stopPrank();

        // Takers hold tokenA to pay in and approve the router.
        tokenA.mint(hook, 1_000e18);
        tokenA.mint(stranger, 1_000e18);
        vm.prank(hook);
        tokenA.approve(address(router), type(uint256).max);
        vm.prank(stranger);
        tokenA.approve(address(router), type(uint256).max);
    }

    /// Program: LiquidationGate (bare, 0xf9 with length 0) then a constant-product XYC swap over the
    /// maker's shipped reserves, then a Salt for a unique order hash.
    function _gatedProgram() internal pure returns (bytes memory) {
        return bytes.concat(hex"f900", XYCSwap.build(), Salt.build(uint64(uint256(keccak256("gate")))));
    }

    function _shipGatedOrder() internal returns (ISwapVM.Order memory order) {
        order = orders.MakerTraitsLibBuild(TraitsHelper.MakerTraitsLibArgs({
            maker: maker,
            receiver: address(0),
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: true,
            usePermit2: false,
            allowZeroAmountIn: false,
            program: _gatedProgram()
        }));
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        uint256[] memory amts = new uint256[](2);
        amts[0] = 1_000e18;
        amts[1] = 1_000e18;
        vm.prank(maker);
        aqua.ship(address(router), abi.encode(order), tokens, amts);
    }

    function _takerData(bool isAToB) internal view returns (bytes memory) {
        return orders.TakerTraitsLibBuild(TraitsHelper.TakerTraitsLibArgs({
            taker: address(0),
            isExactIn: true,
            shouldUnwrapWeth: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: true,
            isAToB: isAToB,
            allowPartialFill: true,
            usePermit2: false,
            threshold: "",
            to: address(0),
            hasPreTransferInCallback: false,
            signature: ""
        }));
    }

    function test_hookTakerFillsThroughAqua() public {
        ISwapVM.Order memory order = _shipGatedOrder();
        // Build taker data BEFORE pranking: TakerTraitsLibBuild is itself a call and would otherwise
        // consume the prank, so router.swap would see the test contract as the taker, not the hook.
        bytes memory taker = _takerData(true);
        uint256 hookBOut = tokenB.balanceOf(hook);
        vm.prank(hook);
        (uint256 amountIn, uint256 amountOut,) = router.swap(order, 10e18, taker);
        assertGt(amountIn, 0, "taker paid tokenA in");
        assertGt(amountOut, 0, "taker received tokenB out");
        assertEq(tokenB.balanceOf(hook) - hookBOut, amountOut, "hook received the fill in tokenB");
    }

    function test_strangerRevertsAtGate() public {
        ISwapVM.Order memory order = _shipGatedOrder();
        bytes memory taker = _takerData(true);
        vm.prank(stranger);
        vm.expectRevert(AutolysisAquaRouterGated.LiquidationGateClosed.selector);
        router.swap(order, 10e18, taker);
    }

    function test_inactiveVenueRevertsAtGate() public {
        ISwapVM.Order memory order = _shipGatedOrder();
        venue.set(false);
        bytes memory taker = _takerData(true);
        vm.prank(hook);
        vm.expectRevert(AutolysisAquaRouterGated.LiquidationGateClosed.selector);
        router.swap(order, 10e18, taker);
    }
}
