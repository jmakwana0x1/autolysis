// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Compiles the devnet's real NaiveStakingRegistry (vendored sidecar source) so `just gate-a-local` can etch
// it on anvil at the devnet's registry address.
import {NaiveStakingRegistry} from "../../lib/mempool-workshop-sidecar/deploy/predeploy/src/contracts/NaiveStakingRegistry.sol";
