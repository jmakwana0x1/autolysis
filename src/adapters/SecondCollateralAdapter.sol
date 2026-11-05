// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ICollateralAdapter} from "./ICollateralAdapter.sol";
import {IRoundFeed} from "../interfaces/IRoundFeed.sol";
import {ISwapVenue} from "../interfaces/ISwapVenue.sol";
import {IERC20Min} from "../interfaces/IERC20Min.sol";

/// @title SecondCollateralAdapter
/// @notice Skeleton adapter for a second collateral asset (Phase 5 deliverable). It wires a per-asset
///         price feed and swap venue behind `ICollateralAdapter`; the wiring compiles and is unit-safe,
///         but the production routing (its own v4 pool + backstop registration) is left as the clearly
///         marked TODO so a second asset can be onboarded without changing the core market.
/// @dev Deliberately minimal: enough structure to show the seam, not a finished second market.
contract SecondCollateralAdapter is ICollateralAdapter {
    address public immutable token;
    IRoundFeed public immutable feed;
    ISwapVenue public venue;
    address public owner;

    error NotOwner();
    error NotWired();

    constructor(address token_, IRoundFeed feed_) {
        token = token_;
        feed = feed_;
        owner = msg.sender;
    }

    function setVenue(ISwapVenue v) external {
        if (msg.sender != owner) revert NotOwner();
        venue = v;
    }

    function collateralToken() external view returns (address) {
        return token;
    }

    function priceWad(uint256 roundId) external view returns (uint256) {
        return feed.priceForLiquidation(roundId);
    }

    function sell(uint256 collateralIn, uint256 minDebtOut, bytes calldata) external returns (uint256 debtOut) {
        if (address(venue) == address(0)) revert NotWired();
        // settle-before-swap, mirroring AutolysisMarket: move collateral to the venue, then swap.
        IERC20Min(token).transfer(address(venue), collateralIn);
        debtOut = venue.sellCollateral(collateralIn, minDebtOut);
        // TODO(phase 5+): register this adapter's own v4 pool + backstop hook and route maker tiers;
        // for now a single venue is enough to exercise the ISelfLiquidatingMarket seam.
    }
}
