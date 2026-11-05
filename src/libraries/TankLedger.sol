// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title TankLedger
/// @notice Borrower-funded gas tank accounting. Guarantee: tank balance plus all billed fees equals
///         total deposits (conservation), and the headroom reported never lets more liquidations be
///         pending than the tank can pay for.
/// @dev Pure bookkeeping over a storage struct; the market owns one ledger per position.
library TankLedger {
    struct Tank {
        uint128 balance; // currently available to pay fees
        uint128 deposited; // lifetime refills
        uint128 billed; // lifetime fees billed (successful + failed attempts)
        uint64 pending; // in-flight liquidation attempts reserved against the tank
    }

    error InsufficientTank();
    error NothingReserved();

    function refill(Tank storage t, uint256 amount) internal {
        t.balance += uint128(amount);
        t.deposited += uint128(amount);
    }

    /// @notice Reserve headroom for one attempt billed at most `feeCap`; reverts if the tank can't pay.
    function reserve(Tank storage t, uint256 feeCap) internal {
        uint256 committed = uint256(t.pending) * feeCap;
        if (uint256(t.balance) < committed + feeCap) revert InsufficientTank();
        t.pending += 1;
    }

    /// @notice Settle a reserved attempt, billing `actual` (<= feeCap). Releases the reservation.
    function settle(Tank storage t, uint256 actual) internal {
        if (t.pending == 0) revert NothingReserved();
        t.pending -= 1;
        t.balance -= uint128(actual);
        t.billed += uint128(actual);
    }

    /// @notice How many more attempts of size `feeCap` the tank can currently back.
    function headroom(Tank storage t, uint256 feeCap) internal view returns (uint256) {
        if (feeCap == 0) return type(uint256).max;
        uint256 committed = uint256(t.pending) * feeCap;
        if (uint256(t.balance) <= committed) return 0;
        return (uint256(t.balance) - committed) / feeCap;
    }

    /// @notice Conservation residual: deposited - balance - billed. Must always be zero.
    function drift(Tank storage t) internal view returns (int256) {
        return int256(uint256(t.deposited)) - int256(uint256(t.balance)) - int256(uint256(t.billed));
    }
}
