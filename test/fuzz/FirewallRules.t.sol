// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FirewallRules} from "../../src/libraries/FirewallRules.sol";
import {TxView, FrameView, FrameTypes, CanonicalView} from "../../src/frame/FrameTypes.sol";
import {CanonicalFrom} from "../mocks/CanonicalFrom.sol";
import {MockFrameEnv} from "../mocks/MockFrameEnv.sol";
import {ProbeConstants} from "../../src/generated/ProbeConstants.sol";

/// @notice The firewall contract: approve exactly one transaction shape per (position, step). Start
///         from the canonical tx, mutate exactly one field, derive the fixed `CanonicalView` the devnet
///         would report (`CanonicalFrom`, which MockFrameEnv is checked to agree with), and assert the
///         rules reject. The positive property: the unmutated canonical tx always approves.
contract FirewallRulesTest is Test {
    address constant ACCOUNT = address(0xA11CE);
    address constant MARKET = address(0x3A12E7);
    uint256 constant POS = 42;
    uint256 constant ROUND = 7;
    uint256 constant SEQ = 3;
    uint256 constant NOW = 1_000_000;

    function _expect() internal pure returns (FirewallRules.Expect memory e) {
        e.account = ACCOUNT;
        e.market = MARKET;
        e.positionId = POS;
        e.roundId = ROUND;
        e.feeCapTotal = 1_000_000 gwei;
        e.firstUseStateCost = ProbeConstants.FIRST_USE_KEY_STATE_GAS;
        e.keyIsNew = true;
    }

    function _canonical() internal pure returns (TxView memory v) {
        v.sender = ACCOUNT;
        v.nonceKeys = new uint256[](1);
        v.nonceKeys[0] = FirewallRules.nonceKey(MARKET, POS);
        v.sequence = SEQ;
        v.feeParam = 1_000_000 gwei; // total-cost format (matches ProbeConstants default)
        v.currentFrame = 0;
        v.frames = new FrameView[](2);
        v.frames[0] = FrameView({
            mode: FrameTypes.MODE_VERIFY,
            target: ACCOUNT,
            gasLimit: 200_000,
            stateLimit: ProbeConstants.FIRST_USE_KEY_STATE_GAS + 50_000,
            value: 0,
            allowedScope: FrameTypes.SCOPE_EXECUTION_AND_PAYMENT,
            data: abi.encodeWithSelector(FirewallRules.VERIFY_SEL)
        });
        v.frames[1] = FrameView({
            mode: FrameTypes.MODE_SENDER,
            target: ACCOUNT,
            gasLimit: 300_000,
            stateLimit: 0,
            value: 0,
            allowedScope: FrameTypes.SCOPE_NONE,
            data: abi.encodeWithSelector(FirewallRules.EXECUTE_SEL, POS, ROUND)
        });
    }

    // Positive property: the canonical tx approves.
    function test_canonicalApproves() public pure {
        assertEq(uint256(_check(_canonical(), _expect())), uint256(FirewallRules.Reject.OK));
    }

    function _check(TxView memory v, FirewallRules.Expect memory e) internal pure returns (FirewallRules.Reject) {
        return FirewallRules.check(CanonicalFrom.from(v), e);
    }

    function _rejects(TxView memory v) internal pure {
        FirewallRules.Reject r = _check(v, _expect());
        assertTrue(r != FirewallRules.Reject.OK, "mutation was not rejected");
    }

    function _rejectsC(CanonicalView memory c) internal pure {
        assertTrue(FirewallRules.check(c, _expect()) != FirewallRules.Reject.OK, "mutation was not rejected");
    }

    // --- single-field mutations: each must flip OK -> reject ---

    function test_mut_frameCount() public pure {
        TxView memory v = _canonical();
        FrameView[] memory f = new FrameView[](3);
        f[0] = v.frames[0];
        f[1] = v.frames[1];
        f[2] = v.frames[1];
        v.frames = f;
        _rejects(v);

        TxView memory v2 = _canonical();
        FrameView[] memory g = new FrameView[](1);
        g[0] = v2.frames[0];
        v2.frames = g;
        _rejects(v2);
    }

    function test_mut_frameOrder() public pure {
        TxView memory v = _canonical();
        FrameView memory tmp = v.frames[0];
        v.frames[0] = v.frames[1];
        v.frames[1] = tmp;
        _rejects(v);
    }

    function test_mut_verifyAllowedScope(uint256 scope) public pure {
        vm.assume(scope != FrameTypes.SCOPE_EXECUTION_AND_PAYMENT);
        TxView memory v = _canonical();
        v.frames[0].allowedScope = scope;
        _rejects(v);
    }

    function test_mut_execMode(uint8 m) public pure {
        vm.assume(m != FrameTypes.MODE_SENDER);
        TxView memory v = _canonical();
        v.frames[1].mode = m;
        _rejects(v);
    }

    function test_mut_execTarget(address x) public pure {
        vm.assume(x != ACCOUNT);
        TxView memory v = _canonical();
        v.frames[1].target = x;
        _rejects(v);
    }

    function test_mut_execSelector(bytes4 sel) public pure {
        vm.assume(sel != FirewallRules.EXECUTE_SEL);
        TxView memory v = _canonical();
        v.frames[1].data = abi.encodeWithSelector(sel, POS, ROUND);
        _rejects(v);
    }

    function test_mut_calldataLen(uint8 extra) public pure {
        vm.assume(extra > 0 && extra < 64);
        TxView memory v = _canonical();
        v.frames[1].data = abi.encodePacked(v.frames[1].data, new bytes(extra));
        _rejects(v);
    }

    function test_mut_positionId(uint256 x) public pure {
        vm.assume(x != POS);
        TxView memory v = _canonical();
        v.frames[1].data = abi.encodeWithSelector(FirewallRules.EXECUTE_SEL, x, ROUND);
        _rejects(v);
    }

    function test_mut_roundId(uint256 x) public pure {
        vm.assume(x != ROUND);
        TxView memory v = _canonical();
        v.frames[1].data = abi.encodeWithSelector(FirewallRules.EXECUTE_SEL, POS, x);
        _rejects(v);
    }

    function test_mut_keyValue(uint256 x) public pure {
        uint256 good = FirewallRules.nonceKey(MARKET, POS);
        vm.assume(x != good && x >> 248 == 0);
        TxView memory v = _canonical();
        v.nonceKeys[0] = x;
        _rejects(v);
    }

    function test_mut_keyTopByte(uint8 top) public pure {
        vm.assume(top != 0);
        TxView memory v = _canonical();
        v.nonceKeys[0] = (uint256(top) << 248) | FirewallRules.nonceKey(MARKET, POS);
        _rejects(v);
    }

    function test_mut_secondKey(uint256 extra) public pure {
        TxView memory v = _canonical();
        uint256[] memory keys = new uint256[](2);
        keys[0] = v.nonceKeys[0];
        keys[1] = extra;
        v.nonceKeys = keys;
        _rejects(v);
    }

    function test_mut_feeAboveCap(uint256 fee) public pure {
        fee = bound(fee, 1_000_000 gwei + 1, type(uint128).max);
        TxView memory v = _canonical();
        v.feeParam = fee;
        _rejects(v);
    }

    function test_mut_stateBudgetTooLow(uint256 sl) public pure {
        sl = bound(sl, 0, ProbeConstants.FIRST_USE_KEY_STATE_GAS - 1);
        TxView memory v = _canonical();
        v.frames[0].stateLimit = sl;
        _rejects(v);
    }

    // No-op: if the key is not new, a low state budget is fine (don't over-reject).
    function test_notNewKeyAllowsLowBudget() public pure {
        TxView memory v = _canonical();
        v.frames[0].stateLimit = 0;
        FirewallRules.Expect memory e = _expect();
        e.keyIsNew = false;
        assertEq(uint256(_check(v, e)), uint256(FirewallRules.Reject.OK));
    }

    function test_mut_execValue(uint256 value) public pure {
        vm.assume(value != 0);
        TxView memory v = _canonical();
        v.frames[1].value = value;
        _rejects(v);
    }

    // Each of the execute frame's three calldata words, corrupted anywhere in its live bytes, rejects.
    // (Word 2 carries only 4 live bytes; the rest is past the 68-byte data and reads as zero on chain.)
    function test_mut_execWords(uint8 which, bytes32 flip) public pure {
        which = uint8(bound(which, 0, 2));
        CanonicalView memory c = CanonicalFrom.from(_canonical());
        if (which == 2) flip &= bytes32(uint256(type(uint32).max) << 224);
        vm.assume(flip != 0);
        if (which == 0) c.execWord0 ^= flip;
        else if (which == 1) c.execWord1 ^= flip;
        else c.execWord2 ^= flip;
        _rejectsC(c);
    }

    function test_mut_keyCountZero() public pure {
        TxView memory v = _canonical();
        v.nonceKeys = new uint256[](0);
        _rejects(v);
    }

    // Out of scope for the rules since A1, by design: sender, frame 0 mode/target/selector and the frame
    // gas limits are not in CanonicalView. Sender and frame 0 target are enforced by APPROVE itself
    // (resolved_target == tx.sender == ADDRESS); frame 0 mode is a devnet probe (B3). Pin that the rules
    // do not look at them, so a future change that starts depending on them is a visible decision.
    function test_rulesIgnoreApproveEnforcedFields(address x, uint8 m, uint256 gl) public pure {
        TxView memory v = _canonical();
        v.sender = x;
        v.frames[0].target = x;
        v.frames[0].mode = m;
        v.frames[0].gasLimit = gl;
        v.frames[1].gasLimit = gl;
        v.frames[0].data = hex"deadbeef";
        assertEq(uint256(_check(v, _expect())), uint256(FirewallRules.Reject.OK));
    }

    // The mock's per-opcode helper tables reproduce the reference derivation, through the same
    // CanonicalReader code the devnet env runs.
    function test_mockAgreesWithReference(uint8 kind, uint256 x) public {
        TxView memory v = _canonical();
        kind = uint8(bound(kind, 0, 5));
        if (kind == 1) v.frames[1].data = abi.encodeWithSelector(FirewallRules.EXECUTE_SEL, x, x >> 7);
        if (kind == 2) v.frames[1].value = x;
        if (kind == 3) v.nonceKeys[0] = x;
        if (kind == 4) v.frames[1].data = abi.encodePacked(v.frames[1].data, uint8(x));
        if (kind == 5) {
            FrameView[] memory one = new FrameView[](1);
            one[0] = v.frames[0];
            v.frames = one;
        }
        MockFrameEnv env = new MockFrameEnv();
        env.set(v);
        assertEq(keccak256(abi.encode(env.loadCanonical())), keccak256(abi.encode(CanonicalFrom.from(v))));
    }
}
