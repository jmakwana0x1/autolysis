# Devnet facts (Hegota alt-mempool, chain 1337)

Authoritative devnet facts, read from the vendored sources and confirmed in code. **These override any
assumption in `PLAN-v4.3.md` / `REVIEW-3`.** Sources (vendored as submodules):

- `lib/mempool-workshop` @ `bcfe02a` — `forshtat/mempool-workshop`
- `lib/mempool-workshop-sidecar` @ `2e22ff0` — `forshtat/mempool-workshop-sidecar`

Chain 1337, 6-second blocks. Faucet is 1 ETH. **The devnet resets at any time and the ethrex image tracks
a moving branch — rerun the probes before every demo.** Nothing here is `on devnet` yet (this build has no
RPC to those hosts); every status below is `local test` / `written, not run` until re-measured on chain via
`ethrex_simulateFrameTransaction`.

## Endpoints

| What | URL |
| --- | --- |
| Gateway sidecar (send everything here) | `https://altmempoolgateway.forshtat.com/rpc` |
| Miner sidecar | `https://altmempool.forshtat.com/rpc` |
| ethrex root (simulate, receipts, `debug_*`) | `https://altmempool.forshtat.com` |
| Explorer | `https://explorer.altmempool.wtf/` |

Checked Nov 5 (laptop): `gateway{1,2,3}.altmempool.wtf` and `devnet{1,2,3}.altmempool.wtf` are **not**
nodes. `*.altmempool.wtf` is wildcard DNS to Vercel: HTTPS fails the TLS handshake and HTTP answers
`404 X-Vercel-Error: DEPLOYMENT_NOT_FOUND`, exactly like a made-up subdomain. Only the forshtat.com
endpoints above serve chain 1337. The gateway faucet there answered `The faucet is empty` (Nov 5, 19:14 UTC).

## Sending and probing

- **Alt mempool:** `eth_sendFrameTransaction([toWire(tx)])` → gateway.
- **Canonical mempool:** `eth_sendRawTransaction([encodeRawFrameTx(tx)])` → gateway, forwarded to ethrex
  (workshop step 6).
- **Status/receipts:** `skandha_frameTransactionStatus(hash)`, `eth_getFrameTransactionReceipt(hash)`
  (per-frame status + logs), ethrex `eth_getTransactionReceipt`.
- **Dry run / the probe tool:** `ethrex_simulateFrameTransaction([rawTx, "latest", {trace:true}])` on the
  **root** URL → `valid`, `violation`, `maxCost`, `payer`, `frames[{gasUsed, succeeded}]`, `erc7562Trace`.
  `maxCost` settles the fee-format question directly.
- **Gas estimate:** `eth_estimateFrameTransactionGas([partialTx])` on `/rpc`.

## Signatures (answers REVIEW-3 R4)

Schemes (`lib/mempool-workshop-sidecar/packages/types/src/contracts/FrameTx.ts`): `0` ARBITRARY (no crypto
check; the account's logic decides), `1` SECP256K1, `2` P256.

- **Keyless liquidation uses one ARBITRARY entry:** `{scheme: 0, signer: "0x", msg: "0x", signature: "0x"}`.
- Probe whether an **empty** list is also accepted; default to ARBITRARY.
- Per-scheme signature-verification cost counts toward `MAX_VERIFY_GAS`
  (`validationPrefix.ts` `SIGNATURE_VERIFICATION_GAS_COST`): **ARBITRARY = 100**, SECP256K1 = 2800,
  P256 = 6700.

## Staking (answers REVIEW-3 R2)

`NaiveStakingRegistry` at **`0xd51c04d7a0b01124e84de152f4e56d9eecb22d2f`**.

- `addStake(uint32 unstakeDelaySec) payable`, `unlockStake()`, `withdrawStake(address)`,
  `getDepositInfo(address) → (uint256 stake, uint32 unstakeDelaySec, uint64 withdrawTime)`.
- Stake is keyed on **msg.sender**. **minStake = 0.01 ETH**, unstake delay 86,400 s. A withdrawal in
  progress disqualifies the stake (STAKING-010).
- **Our route:** owner sends a normal legacy tx to `AutolysisAccount.stake{value: 0.012 ether}(86400)`,
  which calls `registry.addStake`; the account is then `msg.sender`/the staked entity. No frame tx needed
  (our VERIFY only approves liquidations, so we don't need the workshop's self-relay SENDER-frame stake).
- Verify with `getDepositInfo(account)` and `skandha_explorer_listReputation` (`isStaked`).

## Mempool limits that shape the design

### MAX_VERIFY_GAS = 100,000 — staked or not (this is the big one)

`lib/mempool-workshop-sidecar/packages/executor/src/services/UserOpValidation/utils/validationPrefix.ts`:
`MAX_VERIFY_GAS = 100_000` (line 10), `MAX_VERIFY_STATE_GAS = 500_000` (line 44). The rule (line 288):
**the sum of the validation prefix's declared `limits.execution` + the signature-verification cost must be
≤ 100,000.** The ERC-8421 1M staked allowance is **not** in this sidecar.

So, with one ARBITRARY signature (100 gas), the VERIFY frame's `limits.execution` must be ≤ **99,900**, and
that limit must still cover the frame's actual gas.

Measured here — **mock only** (`test/scenarios/A1_verify_gas.t.sol`, after A1 slim VERIFY):

| VERIFY path | pre-A1 mock | A1 mock (cold) | admissible limit ≤ 99,900? (mock) |
| --- | --- | --- | --- |
| outside reads (3 market/feed CALLs) | 131,589 | **71,822** | yes (~28k margin) |
| storage-only snapshot (W1.5) | 98,581 | **50,414** | yes (~49k margin) |

What changed in A1: `IFrameEnv.loadCanonical()` returns a fixed-size `CanonicalView` (15 opcode reads, no
dynamic ABI decoding) instead of the whole `TxView`; the `Approved` event is gone; `MockFrameEnv` answers
each read with one STATICCALL to a per-opcode helper whose answers are constants in its code (the pre-A1
mock paid one SLOAD per field plus ~45k of mock-only SSTORE bookkeeping inside APPROVE). The A1 method
(`test/mocks/VerifyGas.sol`) starts every contract, slot and helper cold except the account address.
The two columns are different methods, so the drop is partly real slimming and partly a fairer mock.

**Decision is A5's, on devnet numbers.** The mock now admits both paths, but real helper and opcode
costs differ; the authoritative number per demo is `frames[0].gasUsed` from
`ethrex_simulateFrameTransaction`. If the real number exceeds 99,900, slim further in this order:
1. ~~read only the frame params actually checked, not the whole `env.load()`~~ (done in A1);
2. cache helper addresses as immutables / call the helpers from the account directly (saves the env hop);
3. keep only shape, key, unhealthy-at-cited-round, fee cap, scope — leave the rest to
   `executeLiquidation`'s recheck;
4. last resort: the community solc fork (`chiranjeev13/solidity` v0.8.38-eip8141.0, inline opcodes).

### Per-sender pending limit = 4

`.../MempoolService/constants.ts:1` `MAX_MEMPOOL_USEROPS_PER_SENDER = 4`. Above 4 pending the sender must
be **staked**; staked senders have no cap unless THROTTLED (then 4). **The crash demo needs 12 pending, so
the account must be staked and not throttled.**

### Other rules

- A pending tx is `(sender, nonce_keys, nonce_seq)`. Replacement needs the same nonce and **both** fees ≥ +10%.
- Next sequence per key: `eth_getStorageAt(NONCE_MANAGER=0x…8250, keccak256(pad32(sender) ‖ uint256(key)))`
  (workshop step 12).
- Validation frames are read-only: any write or value transfer reverts.
- A freshly created contract account starts at **nonce 1**. A SENDER frame that creates an account needs
  `limits.state > 0`.
- Deploys need ~6M gas (legacy gas price 0.002 gwei; base fee ~7 wei). A frame tx's `maxFeePerGas` is 2 gwei
  in the workshop.

## Canonical vs alt — the crash demo's real reasons (exact strings for the dashboard)

- Canonical (ethrex) rejects VERIFY reading another contract's storage with **`StorageReadNonSender`**
  (workshop step 6, `ViolatingWallet` reading `Foreign`; sidecar violation enum noted at
  `.../validators/frameTx.ts:179`).
- Alt rejects it for an **unstaked** entity: `unstaked <role> accessed <addr> slot <slot>`
  (`.../validators/frameTx.ts:798`), and **admits** it once staked (steps 7–8).
- Capture these exact strings from the live RPC for the dashboard.

## Uniswap v4 is predeployed (real bytecode) — plan change

| Contract | Address |
| --- | --- |
| PoolManager | `0x6bF9Aa9c04fd001385742d61f6818C3236429848` |
| PositionManager | `0x5bF24B2CD6f4cc0057F4BeD53264d591620Af57B` |
| StateView | `0xd89a052862AaA34f0B6cc7f3B6a9D080584a43FB` |
| Quoter | `0xeEa49CC6419125E2f706bf7f95Cf34ac7e93087D` |
| Universal Router | `0x5e2250a42608a5cc9f62e23ab24824ee25b5e2be` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| WETH9 | `0x1b7d32025F7cA633943BbCC9Ec61a98ef66187b6` (no premint; `deposit()`) |
| USDC (real; deployer-only mint) | `0xEFe0D421fD473564c9C9b0cDCeB194cF476D6AF5` — **we can't mint; use MockUSDC** |

- **Deploy the BackstopHook against the predeployed PoolManager on the devnet**, so the EF and Uniswap
  proofs happen in one tx, on one chain, with official v4 bytecode.
- The Unichain fork stays for the **1inch** proof (official Aqua registry there). Optionally also deploy
  Aqua from vendored official source on the devnet — label that copy "official source, self-deployed".
- Unichain Sepolia (W3.4) is now optional.

## Reputation / admission data (EXO-010 + dashboard)

- `skandha_explorer_listReputation({limit, cursor})` → real seen/included counters + status
  (ok/throttled/banned). Use for probe 8 and live EXO-010 measurement.
- `skandha_explorer_getTransaction(hash)` / `skandha_explorer_listAdmissions` → per-rule admission verdicts
  + lifecycle, for the dashboard's "why admitted / why rejected" panel.
- `debug_bundler_setReputation` / `dumpReputation` are open. **Use `set*` only for our own account**, label
  any staged throttle as a declared shortcut (workshop step 9). **Never `clear*`** — the devnet is shared.

## Probe rewrite (replaces REVIEW-3 R3)

Every probe uses `ethrex_simulateFrameTransaction` with `{trace:true}`; no invented methods.
1. **Opcodes:** simulate a VERIFY frame calling `ProbeOpcodes`; check `frames[i].succeeded` + trace values.
2. **Fee:** read `maxCost` from simulate.
3. **Staked reads:** simulate `verifyLiquidation` before/after staking; record `violation`.
4. **VERIFY gas:** `frames[0].gasUsed` must be ≤ 99,900 (100k − ARBITRARY 100).
5. **Empty vs ARBITRARY signature:** simulate both.
6. **Replacement:** real send, then +10% resend with same key+sequence; check `skandha_frameTransactionStatus`.
7. **Reputation:** `skandha_explorer_listReputation` before/after.
