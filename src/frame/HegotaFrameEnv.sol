// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IFrameEnv} from "./IFrameEnv.sol";
import {CanonicalView} from "./FrameTypes.sol";
import {CanonicalReader} from "./CanonicalReader.sol";
import {HegotaSupport, Devnet, Scope, TxParam, FrameParam} from "@forshtat/hegota-support/contracts/HegotaSupport.sol";

/// @title HegotaFrameEnv
/// @notice Devnet implementation of `IFrameEnv`. It owns no opcode bytes: it inherits `HegotaSupport`
///         (hegota-support @ 2377188), whose `txparam` / `frameparam` / `framedataload` / `approve`
///         are the real frame opcodes wrapped as Solidity functions, each a per-contract immutable Yul
///         helper. `approve` acts on the executing account, so the account reaches it through the same
///         DELEGATECALL it already uses; the reads are STATICCALLs.
/// @dev The chosen devnet is the public alt-mempool tracer (ERC8421_WORKSHOP, chain 1337).
contract HegotaFrameEnv is IFrameEnv, HegotaSupport, CanonicalReader {
    constructor() HegotaSupport(Devnet.ERC8421_WORKSHOP) {}

    function loadCanonical() external view returns (CanonicalView memory) {
        return _loadCanonical();
    }

    function maxCost() external view returns (uint256) {
        return txparam(TxParam.MAX_COST);
    }

    function approve(uint256 scope) external {
        // Reached by DELEGATECALL from the account, so APPROVE acts on the account. `scope` is a Scope.
        approve(Scope(scope));
    }

    function _txparam(uint256 id) internal view override returns (uint256) {
        return txparam(TxParam(id));
    }

    function _frameparam(uint256 frameIndex, uint256 id) internal view override returns (uint256) {
        return frameparam(frameIndex, FrameParam(id));
    }

    function _framedataload(uint256 offset, uint256 frameIndex) internal view override returns (bytes32) {
        return framedataload(offset, frameIndex);
    }
}
