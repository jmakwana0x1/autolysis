// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

// Fork of 1inch SwapVM's AquaSwapVMRouter (swap-vm @ f9f4acf), kept under its SwapVM-1.1 license (see
// ./LICENSES/SwapVM-1.1.txt): modifications must stay under the same license. The only change is one
// new opcode, LiquidationGate, handled in _dispatch before the standard opcode set.

import {Context} from "@1inch/swap-vm/contracts/libs/VM.sol";
import {Simulator} from "@1inch/solidity-utils/contracts/mixins/Simulator.sol";
import {SwapVM} from "@1inch/swap-vm/contracts/SwapVM.sol";
import {AquaOpcodes} from "@1inch/swap-vm/contracts/opcodes/AquaOpcodes.sol";

interface IGateVenue {
    function liquidationActive() external view returns (bool);
}

/// @title AutolysisAquaRouterGated
/// @notice AquaSwapVMRouter plus a LiquidationGate opcode: a gated maker program can only be filled by
///         the Autolysis backstop hook, and only while its venue reports an active liquidation. Makers
///         ship a strategy whose FIRST instruction is this gate, so no one outside a liquidation can
///         fill it. Everything after the gate is the standard Aqua program (oracle pricing, swap).
contract AutolysisAquaRouterGated is Simulator, SwapVM, AquaOpcodes {
    /// Unused Opcode slot 0xf9 (`_f9`) in SwapVM's enum, claimed for the gate.
    uint256 internal constant LIQUIDATION_GATE = 0xf9;

    address public immutable gateHook;
    address public immutable gateVenue;

    error LiquidationGateClosed();

    constructor(
        address aqua,
        address weth,
        address owner,
        string memory name,
        string memory version,
        address hook,
        address venue
    ) SwapVM(aqua, weth, owner, name, version) {
        gateHook = hook;
        gateVenue = venue;
    }

    /// @dev LiquidationGate reverts unless the taker is the hook and a liquidation is active; otherwise
    ///      dispatch falls through to the standard opcode handlers.
    function _dispatch(Context memory ctx, uint256 opcode, bytes calldata args) internal override {
        if (opcode == LIQUIDATION_GATE) {
            if (ctx.query.taker != gateHook || !IGateVenue(gateVenue).liquidationActive()) {
                revert LiquidationGateClosed();
            }
            return; // gate passed
        }
        _runOpcode(ctx, opcode, args);
    }
}
