// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IFrameEnv} from "../../src/frame/IFrameEnv.sol";
import {TxView, CanonicalView} from "../../src/frame/FrameTypes.sol";
import {CanonicalReader} from "../../src/frame/CanonicalReader.sol";
import {ProbeConstants} from "../../src/generated/ProbeConstants.sol";
import {CanonicalFrom} from "./CanonicalFrom.sol";

/// @notice Foundry stand-in for the frame opcodes, cost-realistic for VERIFY gas (A1).
/// @dev Shape mirrors `HegotaFrameEnv`: the account STATICCALLs this env, whose `loadCanonical()` is the
///      shared `CanonicalReader` code, and every field is one STATICCALL to a per-opcode helper
///      (TXPARAM, FRAMEPARAM, FRAMEDATALOAD) at an immutable address. A helper's answers are a constant
///      table in its own code (`set()` re-etches it), so a read costs a call plus CODECOPY, never an
///      SLOAD. APPROVE touches a fourth (cold) helper, as the real path does, and records into
///      transient storage; the record is settled into storage on the next `set()`/`resetApprovals()`,
///      which tests call outside the measured window. This relies on `isolate = false` (foundry.toml).
///      Keyed-nonce consumption is modelled: the per-key sequence advances at APPROVE, success or
///      failure, so a failed attempt still burns the nonce (C2).
contract MockFrameEnv is IFrameEnv, CanonicalReader {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// Helper runtime: return word `calldata[0]` of the table appended after these 19 bytes.
    /// PUSH1 32, PUSH1 0, CALLDATALOAD, PUSH1 5, SHL, PUSH1 19, ADD, PUSH1 0, CODECOPY,
    /// PUSH1 32, PUSH1 0, RETURN. Reading past the table yields zero (CODECOPY pads).
    bytes private constant HELPER_HEAD = hex"60206000356005" hex"1b601301600039" hex"60206000f3";
    bytes private constant REVERT_CODE = hex"5f5ffd";
    uint256 private constant FRAME_STRIDE = 16; // FRAMEPARAM ids < 16; FRAMEDATALOAD words per frame

    address private immutable SELF;
    address private immutable TXH;
    address private immutable FRH;
    address private immutable DLH;
    address private immutable APH;

    bytes32 private constant T_ACCOUNT = keccak256("mock.pending.account");
    bytes32 private constant T_SCOPE = keccak256("mock.pending.scope");
    bytes32 private constant T_KEY = keccak256("mock.current.key");
    bytes32 private constant T_HAS_KEY = keccak256("mock.current.hasKey"); // 1 iff exactly one nonce key

    mapping(address => uint256) private settledScope; // scope + 1
    mapping(uint256 => uint256) private settledSequence;
    uint256 private settledCount;
    bool public failLoad;

    constructor() {
        SELF = address(this);
        TXH = _derive("txparam");
        FRH = _derive("frameparam");
        DLH = _derive("framedataload");
        APH = _derive("approve");
        vm.etch(APH, hex"00");
    }

    // ------------------------------------------------------------------ test controls (unmeasured)

    function set(TxView memory v) external {
        _settle();
        CanonicalView memory c = CanonicalFrom.from(v);
        // The table is the full TxView (what the opcodes would answer), not the canonical slice.
        uint256[] memory t = new uint256[](17);
        t[ProbeConstants.TX_NONCE] = v.sequence;
        t[ProbeConstants.TX_SENDER] = uint160(v.sender);
        t[ProbeConstants.TX_MAX_COST] = v.feeParam;
        t[ProbeConstants.TX_FRAME_COUNT] = v.frames.length;
        t[ProbeConstants.TX_CURRENT_FRAME_INDEX] = v.currentFrame;
        t[ProbeConstants.TX_NONCE_KEY_COUNT] = v.nonceKeys.length;
        if (v.nonceKeys.length != 0) t[ProbeConstants.TX_NONCE_KEY_0] = v.nonceKeys[0];
        vm.etch(TXH, _code(t));

        uint256 n = v.frames.length;
        uint256[] memory f = new uint256[](n * FRAME_STRIDE);
        uint256[] memory d = new uint256[](n * FRAME_STRIDE);
        for (uint256 i; i < n; ++i) {
            uint256 b = i * FRAME_STRIDE;
            f[b + ProbeConstants.FR_RESOLVED_TARGET] = uint160(v.frames[i].target);
            f[b + ProbeConstants.FR_EXECUTION_GAS_LIMIT] = v.frames[i].gasLimit;
            f[b + ProbeConstants.FR_MODE] = v.frames[i].mode;
            f[b + ProbeConstants.FR_DATA_LENGTH] = v.frames[i].data.length;
            f[b + ProbeConstants.FR_ALLOWED_SCOPE] = v.frames[i].allowedScope;
            f[b + ProbeConstants.FR_VALUE] = v.frames[i].value;
            f[b + ProbeConstants.FR_STATE_GAS_LIMIT] = v.frames[i].stateLimit;
            for (uint256 w; w < FRAME_STRIDE; ++w) {
                d[b + w] = uint256(CanonicalFrom.word(v.frames[i].data, w * 32));
            }
        }
        vm.etch(FRH, failLoad ? REVERT_CODE : _code(f));
        vm.etch(DLH, _code(d));
        _tstore(T_KEY, c.nonceKey0);
        _tstore(T_HAS_KEY, c.nonceKeyCount == 1 ? 1 : 0);
    }

    /// Make frame reads revert (so `loadCanonical()` reverts) while `maxCost()` keeps working.
    function setFailLoad(bool v) external {
        failLoad = v;
        if (v) vm.etch(FRH, REVERT_CODE);
    }

    function resetApprovals(address account) external {
        _settle();
        delete settledScope[account];
    }

    // ------------------------------------------------------------------ IFrameEnv (measured)

    function loadCanonical() external view returns (CanonicalView memory) {
        return _loadCanonical();
    }

    function maxCost() external view returns (uint256) {
        return _txparam(ProbeConstants.TX_MAX_COST);
    }

    /// @dev Reached through DELEGATECALL from the account, so `address(this)` is the account.
    function approve(uint256 scope) external {
        (bool ok,) = APH.staticcall(""); // the real APPROVE helper is one cold delegatecall away
        require(ok);
        MockFrameEnv(SELF).record(address(this), scope);
    }

    function record(address account, uint256 scope) external {
        require(msg.sender == account, "MockFrameEnv: record");
        if (_tload(T_ACCOUNT) != 0) _settle(); // a second APPROVE in one tx: keep the first
        _tstore(T_ACCOUNT, uint160(account));
        _tstore(T_SCOPE, scope + 1);
    }

    // ------------------------------------------------------------------ views

    function isApproved(address account) external view returns (bool) {
        return approvedScope(account) != 0;
    }

    /// scope + 1, or 0 when `account` has not approved since the last reset.
    function approvedScope(address account) public view returns (uint256) {
        if (_tload(T_ACCOUNT) == uint160(account)) return _tload(T_SCOPE);
        return settledScope[account];
    }

    /// Next expected sequence for `key` (advances on every APPROVE).
    function sequenceOf(uint256 key) external view returns (uint256) {
        uint256 s = settledSequence[key];
        if (_tload(T_ACCOUNT) != 0 && _tload(T_HAS_KEY) == 1 && _tload(T_KEY) == key) s += 1;
        return s;
    }

    function approveCount() external view returns (uint256) {
        return settledCount + (_tload(T_ACCOUNT) != 0 ? 1 : 0);
    }

    // ------------------------------------------------------------------ internals

    function _txparam(uint256 id) internal view override returns (uint256) {
        return _read(TXH, id);
    }

    function _frameparam(uint256 frameIndex, uint256 id) internal view override returns (uint256) {
        return _read(FRH, frameIndex * FRAME_STRIDE + id);
    }

    function _framedataload(uint256 offset, uint256 frameIndex) internal view override returns (bytes32) {
        return bytes32(_read(DLH, frameIndex * FRAME_STRIDE + offset / 32));
    }

    /// Same call shape as hegota-support HelperCalls.readWord: abi-encoded operand, bytes output.
    function _read(address helper, uint256 index) private view returns (uint256) {
        (bool ok, bytes memory out) = helper.staticcall(abi.encode(index));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(out, 0x20), mload(out))
            }
        }
        require(out.length == 32, "MockFrameEnv: no frame tx");
        return abi.decode(out, (uint256));
    }

    function _settle() private {
        uint256 acct = _tload(T_ACCOUNT);
        if (acct == 0) return;
        settledScope[address(uint160(acct))] = _tload(T_SCOPE);
        settledCount++;
        if (_tload(T_HAS_KEY) == 1) settledSequence[_tload(T_KEY)] += 1;
        _tstore(T_ACCOUNT, 0);
        _tstore(T_SCOPE, 0);
    }

    function _code(uint256[] memory table) private pure returns (bytes memory) {
        return abi.encodePacked(HELPER_HEAD, table);
    }

    function _derive(string memory tag) private view returns (address) {
        return address(uint160(uint256(keccak256(abi.encode(address(this), tag)))));
    }

    function _tload(bytes32 slot) private view returns (uint256 v) {
        assembly {
            v := tload(slot)
        }
    }

    function _tstore(bytes32 slot, uint256 v) private {
        assembly {
            tstore(slot, v)
        }
    }
}
