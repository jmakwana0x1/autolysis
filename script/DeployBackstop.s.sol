// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BackstopHook} from "../src/backstop/BackstopHook.sol";
import {IRoundFeed} from "../src/interfaces/IRoundFeed.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @notice Mines a CREATE2 salt so the hook lands at an address encoding exactly its permission bits,
///         deploys it there, and asserts `validateHookAddress()`. The live hook must sit at a
///         flag-matching address (tests install the code with vm.etch instead).
contract DeployBackstop is Script {
    uint160 constant FLAGS =
        uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);

    function mineSalt(address deployer, IPoolManager manager, address owner, IRoundFeed feed, Currency debt)
        public
        pure
        returns (bytes32 salt, address predicted)
    {
        bytes memory initcode =
            abi.encodePacked(type(BackstopHook).creationCode, abi.encode(manager, owner, feed, debt));
        bytes32 initHash = keccak256(initcode);
        for (uint256 i; i < 200_000; ++i) {
            salt = bytes32(i);
            predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initHash)))));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == FLAGS) return (salt, predicted);
        }
        revert("no salt found");
    }

    function run(IPoolManager manager, address owner, IRoundFeed feed, Currency debt)
        external
        returns (BackstopHook hook)
    {
        (bytes32 salt,) = mineSalt(msg.sender, manager, owner, feed, debt);
        vm.startBroadcast();
        hook = new BackstopHook{salt: salt}(manager, owner, feed, debt);
        vm.stopBroadcast();
        hook.validateHookAddress();
    }
}
