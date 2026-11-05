// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title FrameCellBytecode
/// @notice Assembles the raw-bytecode cells that execute a single frame opcode. Opcode numbers come
///         from `deployments/probes.json` so a renumbered draft is a config change, not a code change.
/// @dev Runtime layouts (calldata = abi.encode(a, b)):
///      two-arg:  PUSH1 0x20 CALLDATALOAD  PUSH1 0 CALLDATALOAD  OP  PUSH1 0 MSTORE  PUSH1 0x20 PUSH1 0 RETURN
///      one-arg:  PUSH1 0 CALLDATALOAD  OP  PUSH1 0 MSTORE  PUSH1 0x20 PUSH1 0 RETURN
///      approve:  PUSH1 0 CALLDATALOAD  OP  STOP          (APPROVE halts the frame like RETURN)
///      `a` ends on top of the stack, i.e. it is the opcode's first operand.
library FrameCellBytecode {
    function twoArg(uint8 op) internal pure returns (bytes memory) {
        return _wrap(abi.encodePacked(hex"602035600035", op, hex"60005260206000f3"));
    }

    function oneArg(uint8 op) internal pure returns (bytes memory) {
        return _wrap(abi.encodePacked(hex"600035", op, hex"60005260206000f3"));
    }

    function approveCell(uint8 op) internal pure returns (bytes memory) {
        return _wrap(abi.encodePacked(hex"600035", op, hex"00"));
    }

    function deploy(bytes memory initcode) internal returns (address a) {
        assembly ("memory-safe") {
            a := create(0, add(initcode, 32), mload(initcode))
        }
        require(a != address(0), "cell deploy failed");
    }

    /// @dev Minimal initcode: copy runtime to memory 0 and return it.
    ///      PUSH1 len  DUP1  PUSH1 0x0b  PUSH1 0  CODECOPY  PUSH1 0  RETURN  <runtime>
    function _wrap(bytes memory runtime) private pure returns (bytes memory) {
        require(runtime.length < 256, "runtime too long");
        return abi.encodePacked(hex"60", uint8(runtime.length), hex"80600b6000396000f3", runtime);
    }
}
