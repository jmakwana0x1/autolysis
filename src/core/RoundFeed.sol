// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRoundFeed} from "../interfaces/IRoundFeed.sol";

/// @title RoundFeed
/// @notice Round-based price feed with a band and a breaker. Guarantee: a liquidation never uses a
///         price outside the band, and a move over 10% between consecutive rounds needs two rounds to
///         take effect (the breaker), so a single spike cannot drive a liquidation.
/// @dev Prices are WAD. `priceForLiquidation` is the only price a liquidation may read; it reverts
///      rather than returning a bad price, so a mispriced round can never silently liquidate.
contract RoundFeed is IRoundFeed {
    uint256 internal constant WAD = 1e18;
    uint256 public constant MAX_MOVE_BPS = 1000; // 10%
    uint256 public constant MAX_AGE = 1 hours; // a round older than this is out of band (SENDER path)
    uint256 public constant VERIFY_WINDOW = 4; // K: VERIFY accepts only the last K rounds (no TIMESTAMP)

    address public updater;
    uint256 public latest;
    mapping(uint256 => Round) internal rounds;

    /// A round that moved more than MAX_MOVE vs the previous accepted price is "pending": it only
    /// becomes usable once a second round confirms a price within the band of it.
    mapping(uint256 => bool) public breakerTripped;

    error NotUpdater();
    error BadRound();
    error PriceOutOfBand();
    error BreakerPending();
    error StaleRound();

    event RoundPosted(uint256 indexed roundId, uint256 price, bool breaker);

    constructor(address updater_, uint256 initialPrice) {
        updater = updater_;
        latest = 1;
        rounds[1] = Round({price: initialPrice, timestamp: block.timestamp, valid: true});
        emit RoundPosted(1, initialPrice, false);
    }

    /// @notice Hand price-posting to another address (used to wire the invariant handler; on the
    ///         devnet the updater is the sidecar oracle relay set once at deploy).
    function transferUpdater(address next) external {
        if (msg.sender != updater) revert NotUpdater();
        updater = next;
    }

    function post(uint256 price) external returns (uint256 roundId) {
        if (msg.sender != updater) revert NotUpdater();
        if (price == 0) revert BadRound();
        roundId = ++latest;
        uint256 prev = rounds[roundId - 1].price;
        bool tripped = _moveExceeds(prev, price);
        rounds[roundId] = Round({price: price, timestamp: block.timestamp, valid: true});
        breakerTripped[roundId] = tripped;
        emit RoundPosted(roundId, price, tripped);
    }

    function latestRound() external view returns (uint256) {
        return latest;
    }

    function getRound(uint256 roundId) external view returns (Round memory) {
        return rounds[roundId];
    }

    function priceForLiquidation(uint256 roundId) external view returns (uint256) {
        Round memory r = rounds[roundId];
        if (!r.valid) revert BadRound();
        if (block.timestamp > r.timestamp + MAX_AGE) revert StaleRound();

        // Breaker: a >10% move needs a confirming next round within band before it is usable.
        if (breakerTripped[roundId]) {
            Round memory next = rounds[roundId + 1];
            if (!next.valid) revert BreakerPending();
            if (_moveExceeds(r.price, next.price)) revert BreakerPending();
        }

        // Band: the cited round must be close to the latest accepted price, unless it IS the latest.
        if (roundId != latest) {
            uint256 ref = rounds[latest].price;
            if (_moveExceeds(ref, r.price)) revert PriceOutOfBand();
        }
        return r.price;
    }

    /// @notice The price to use when VERIFYing a liquidation (validation context, so no TIMESTAMP).
    ///         Freshness is an index window instead of an age: latest - K < roundId <= latest. Also
    ///         enforces the band and the breaker. Reverts rather than return a bad price.
    function checkRoundForVerify(uint256 roundId) external view returns (uint256) {
        if (roundId == 0 || roundId > latest) revert BadRound();
        if (roundId + VERIFY_WINDOW <= latest) revert StaleRound(); // outside the K-round window
        Round memory r = rounds[roundId];
        if (!r.valid) revert BadRound();

        if (breakerTripped[roundId]) {
            Round memory next = rounds[roundId + 1];
            if (!next.valid) revert BreakerPending();
            if (_moveExceeds(r.price, next.price)) revert BreakerPending();
        }
        if (roundId != latest) {
            if (_moveExceeds(rounds[latest].price, r.price)) revert PriceOutOfBand();
        }
        return r.price;
    }

    function _moveExceeds(uint256 a, uint256 b) internal pure returns (bool) {
        if (a == 0) return false;
        uint256 hi = a > b ? a : b;
        uint256 lo = a > b ? b : a;
        return (hi - lo) * 10_000 > a * MAX_MOVE_BPS;
    }
}
