// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ISwapVM} from "@1inch/swap-vm/contracts/interfaces/ISwapVM.sol";
import {MakerTraitsLib} from "@1inch/swap-vm/contracts/libs/MakerTraits.sol";
import {TakerTraitsLib} from "@1inch/swap-vm/contracts/libs/TakerTraits.sol";
import {Extruction} from "@1inch/swap-vm/contracts/instructions/Extruction.sol";
import {Salt} from "@1inch/swap-vm/contracts/instructions/Controls.sol";

/// @notice Test-only bridge for the 0.8.26 tree (C1): builds SwapVM orders, gated oracle programs and
///         exact-in taker data with the REAL upstream encoders (MakerTraitsLib / TakerTraitsLib /
///         Extruction / Salt), so the main-profile test never re-implements SwapVM's byte layout. It is
///         deployed from its aqua-profile artifact with vm.deployCode and called by ABI.
contract OrderBuilder {
    /// [LiquidationGate 0xf9][Extruction -> pricer(priceSource ++ collateral)][Salt]
    function gatedOracleProgram(address pricer, address priceSource, address collateral, uint64 salt)
        external
        pure
        returns (bytes memory)
    {
        return bytes.concat(
            hex"f900", Extruction.build(pricer, abi.encodePacked(priceSource, collateral)), Salt.build(salt)
        );
    }

    /// An Aqua-backed order (no signature) over (tokenA, tokenB) running `program`.
    function aquaOrder(address maker, address tokenA, address tokenB, bytes calldata program)
        external
        pure
        returns (ISwapVM.Order memory)
    {
        return MakerTraitsLib.build(
            MakerTraitsLib.Args({
                maker: maker,
                receiver: address(0),
                tokenA: tokenA,
                tokenB: tokenB,
                shouldUnwrapWeth: false,
                useAquaInsteadOfSignature: true,
                allowZeroAmountIn: false,
                usePermit2: false,
                hasPreTransferInHook: false,
                hasPostTransferInHook: false,
                hasPreTransferOutHook: false,
                hasPostTransferOutHook: false,
                preTransferInTarget: address(0),
                preTransferInData: "",
                postTransferInTarget: address(0),
                postTransferInData: "",
                preTransferOutTarget: address(0),
                preTransferOutData: "",
                postTransferOutTarget: address(0),
                postTransferOutData: "",
                program: program
            })
        );
    }

    /// Exact-in taker data: msg.sender is the taker and the recipient; tokenIn pulled by transferFrom
    /// and pushed to the maker through Aqua.
    function exactInTaker(bool isAToB) external pure returns (bytes memory) {
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: address(0),
                isExactIn: true,
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: false,
                useTransferFromAndAquaPush: true,
                isAToB: isAToB,
                allowPartialFill: true,
                usePermit2: false,
                threshold: "",
                to: address(0),
                deadline: 0,
                hasPreTransferInCallback: false,
                hasPreTransferOutCallback: false,
                preTransferInHookData: "",
                postTransferInHookData: "",
                preTransferOutHookData: "",
                postTransferOutHookData: "",
                preTransferInCallbackData: "",
                preTransferOutCallbackData: "",
                instructionsArgs: "",
                signature: ""
            })
        );
    }
}
