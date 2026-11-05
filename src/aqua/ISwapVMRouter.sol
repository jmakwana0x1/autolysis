// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ISwapVMRouter
/// @notice ABI-exact view of 1inch SwapVM's `ISwapVM` (swap-vm @ f9f4acf), so the 0.8.26 BackstopHook can
///         call the gated router (compiled at 0.8.30) across the solc boundary — the hook only needs the
///         ABI. `MakerTraits` is a `uint256` user type upstream; on the wire it is a uint256.
interface ISwapVMRouter {
    struct Order {
        address maker;
        uint256 traits; // MakerTraits
        bytes data; // packed hooks data + program bytecode (the gated program starts with 0xf9)
    }

    function hash(Order calldata order) external view returns (bytes32);

    function quote(Order calldata order, uint256 amount, bytes calldata takerTraitsAndData)
        external
        view
        returns (uint256 amountIn, uint256 amountOut, bytes32 orderHash);

    function swap(Order calldata order, uint256 amount, bytes calldata takerTraitsAndData)
        external
        payable
        returns (uint256 amountIn, uint256 amountOut, bytes32 orderHash);
}
