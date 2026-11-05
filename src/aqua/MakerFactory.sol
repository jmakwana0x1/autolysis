// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {WalletMakerStrategy} from "./WalletMakerStrategy.sol";
import {IERC20Min} from "../interfaces/IERC20Min.sol";

/// @title MakerFactory
/// @notice Deploys maker strategies as EIP-1167 clones of a single `WalletMakerStrategy` logic contract.
///         Every clone has the same runtime code hash, which the router allowlists once. `cloneCodehash`
///         is that hash, so the owner can allowlist it before any maker exists.
contract MakerFactory {
    address public immutable logic;

    event MakerCreated(address maker, address indexed wallet);

    constructor() {
        logic = address(new WalletMakerStrategy());
    }

    /// @notice The runtime code hash shared by every maker clone (what the router allowlists).
    function cloneCodehash() external view returns (bytes32) {
        return keccak256(_proxyRuntime(logic));
    }

    function create(IERC20Min usdc, address wallet, address router, uint256 maxSize) external returns (address maker) {
        maker = Clones.clone(logic);
        WalletMakerStrategy(maker).initialize(usdc, wallet, router, maxSize);
        emit MakerCreated(maker, wallet);
    }

    /// @dev EIP-1167 minimal-proxy runtime for `impl` (used to precompute the clone code hash).
    function _proxyRuntime(address impl) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"363d3d373d3d3d363d73", impl, hex"5af43d82803e903d91602b57fd5bf3");
    }
}
