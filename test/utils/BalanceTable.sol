// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Prints a markdown before/after balance table to the test log (shown with -vv), so the fork
///         proofs read cleanly in a terminal, in CI logs and pasted into the README.
library BalanceTable {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function header(string memory title) internal pure {
        console2.log("");
        console2.log(string.concat("### ", title));
        console2.log("| Balance | Before | After | Change |");
        console2.log("| --- | ---: | ---: | ---: |");
    }

    /// One row; values are 18-decimal token amounts (WAD), printed to 4 decimals.
    function row(string memory label, uint256 beforeWad, uint256 afterWad) internal pure {
        string memory delta = afterWad >= beforeWad
            ? string.concat("+", fmt(afterWad - beforeWad))
            : string.concat("-", fmt(beforeWad - afterWad));
        if (afterWad == beforeWad) delta = "0";
        console2.log(string.concat("| ", label, " | ", fmt(beforeWad), " | ", fmt(afterWad), " | ", delta, " |"));
    }

    function note(string memory text) internal pure {
        console2.log(text);
    }

    function fmt(uint256 wad) internal pure returns (string memory) {
        uint256 whole = wad / 1e18;
        uint256 frac = (wad % 1e18) / 1e14; // 4 decimals
        string memory f = vm.toString(frac);
        while (bytes(f).length < 4) f = string.concat("0", f);
        return string.concat(vm.toString(whole), ".", f);
    }
}
