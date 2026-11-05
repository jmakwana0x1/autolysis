// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ISwapVMRouter
/// @notice The minimal 1inch SwapVM router ABI the backstop hook needs to fill a liquidation through
///         the gated SwapVM fork (aqua-fork/src/AutolysisAquaRouterGated.sol). That router compiles at
///         solc 0.8.30 with via-IR and cannot be imported into this 0.8.26 tree, so the hook calls it by
///         ABI through this interface instead. `traits` is SwapVM's `MakerTraits` user-defined value
///         type, whose underlying type is uint256, so it ABI-encodes identically here.
/// @dev Tier-1 of the waterfall builds `Order` + `takerTraitsAndData` off-chain (the maker ships the
///      gated program; the hook supplies exact-in taker traits with the hook as taker so the
///      LiquidationGate opens) and calls `swap`. This interface is the drop-in wiring point; the
///      end-to-end cross-solc run happens on the fork where both trees are deployed by one toolchain.
interface ISwapVMRouter {
    struct Order {
        address maker;
        uint256 traits; // SwapVM MakerTraits (type MakerTraits is uint256)
        bytes data;
    }

    /// @notice The order hash Aqua keys the maker's balances on (upstream ISwapVM.hash, view).
    function hash(Order calldata order) external view returns (bytes32);

    /// @notice Fill a shipped order. Reverts (LiquidationGateClosed) unless msg.sender is the gate hook
    ///         and the venue reports an active liquidation.
    function swap(Order calldata order, uint256 amount, bytes calldata takerTraitsAndData)
        external
        payable
        returns (uint256 amountIn, uint256 amountOut, bytes32 orderHash);

    /// @notice Static-call price for the same order; equals `swap`'s result (the pricer is deterministic).
    function quote(Order calldata order, uint256 amount, bytes calldata takerTraitsAndData)
        external
        returns (uint256 amountIn, uint256 amountOut, bytes32 orderHash);
}
