// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMakerStrategy} from "../../src/aqua/IMakerStrategy.sol";

/// Burns all forwarded gas in available() -> the router's stipend cuts it off and skips the maker.
contract GasBombStrategy is IMakerStrategy {
    function available() external view returns (uint256) {
        uint256 x;
        for (uint256 i; i < 1e9; ++i) {
            x = uint256(keccak256(abi.encode(x, i)));
        }
        return x;
    }

    function commit(address, uint256) external pure returns (uint256) {
        return 0;
    }
}

/// Promises USDC in available() but reverts on commit (rug between quote and fill) -> skipped.
contract RugStrategy is IMakerStrategy {
    function available() external pure returns (uint256) {
        return 1_000_000e18;
    }

    function commit(address, uint256) external pure returns (uint256) {
        revert("rugged");
    }
}
