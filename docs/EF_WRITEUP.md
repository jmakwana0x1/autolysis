# Autolysis: self-liquidating loans on the EIP-8141 alt mempool

*Write-up for the Ethereum Foundation alt-mempool track. Labels: **on devnet** · **on fork** ·
**local test** · **mock only** · **written, not run**.*

## 1. The app

A lending position that **liquidates itself**. Every position has an on-chain `AutolysisAccount` that, in
a frame transaction's VERIFY frame, approves exactly one transaction shape: "liquidate position P at
oracle round R". That transaction needs no signature (one ARBITRARY entry), so anyone can carry it. The
account pays its gas as `EXECUTION_AND_PAYMENT`, refilled from the collateral being sold. The SENDER frame
then sells a gradual slice of collateral through a Uniswap v4 pool.

Why it needs the alt mempool:

- **VERIFY reads outside state.** Whether P is unhealthy at R lives in the market and feed, not in the
  account. ethrex's canonical policy rejects that (`StorageReadNonSender`). The alt sidecar admits it for
  a **staked** account (ERC-8421 STO rules), and our account stakes itself (0.012 ETH, 86,400 s delay) in
  the devnet's `NaiveStakingRegistry`.
- **One nonce lane per position.** Each position's liquidations use the EIP-8250 key
  `H(market, positionId)` with the top byte cleared. A crash that makes 12 positions liquidatable at once
  produces 12 pending transactions from one sender that never block each other, and a newer round
  replaces a stale pending one on the same key with a +10% fee bump.
- **It must fit the 100k VERIFY cap.** The sidecar requires the VERIFY limit plus the signature cost to
  be ≤ 100,000 (`validationPrefix.ts:288`). A1 shrank VERIFY to a fixed-size read of 15 frame-opcode
  values. On the devnet, simulate measured **94,168** gas reading outside state and **71,892** on the
  storage-only fallback (**on devnet**; the mock had said 71,822 / 50,414). Outside reads fits, so it is
  the path in use.

What VERIFY checks, and what it leaves to the protocol, is spelled out on `CanonicalView`
(`src/frame/FrameTypes.sol:51`). Sender and frame-0 target are implied by APPROVE
(`resolved_target == tx.sender`). Frame-0 mode is checked explicitly, because "APPROVE is VERIFY-only" is
not in the vendored source.

## 2. Tooling we built (reusable beyond this app)

| Tool | What it does | Label |
| --- | --- | --- |
| `kit/src/sim.ts` | `ethrex_simulateFrameTransaction` called exactly as the sidecar does: the **raw `0x06‖rlp` bytes**, `"latest"`, `{trace}`, parsed into `canonicalMempoolValid/Violation`, per-frame `gasUsed`, `haltReason`/`revertData` | local test |
| `just gate-a` (`kit/src/gateA/`) | the whole bring-up as one unattended, idempotent run: deploy → stake → seed → crash → simulate both VERIFY paths and choose → canonical attempt (exact body saved) → alt send → receipt → balances. It stops on the first error with its exact text and resumes a sent tx by hash rather than resending | local test; devnet written, not run |
| `kit/src/gateA/mockNode.ts` | a JSON-RPC proxy in front of anvil that answers the frame RPCs, emulating the SENDER frame by impersonation and labelling every answer `"mock": true` | mock only |
| `just scene crash \| replace \| attacks \| uniswap-balances` | Phase B as commands. `attacks` simulates and sends five mutations (appended key, wrong selector, fee over cap, stale round, frame 0 in DEFAULT mode), decodes VERIFY's `Rejected(...)` reason, and **never broadcasts** a mutation that simulate says VERIFY would approve | local test; devnet written, not run |
| `just reputation <label>` | `skandha_explorer_listReputation` snapshots for the account (paged `{items, nextCursor}`) as a measured series | local test |
| Dashboard (`just dashboard`) | canonical-vs-alt texts, each tx's lifecycle (VERIFY → admitted → SENDER → tier → gas refilled), net saved, EXO-010 simulated beside measured | local test |

### Findings from the vendored sources, for other builders

- Simulate takes the **raw** encoded transaction, not the JSON wire form, and the verdict fields are
  `canonicalMempoolValid` / `canonicalMempoolViolation`. That is ethrex's canonical verdict; the alt
  verdict only comes from `eth_sendFrameTransaction`. (`FrameTxSimulationService/index.ts:60-63`,
  `ethrexFrameTx.ts:123`.)
- `NaiveStakingRegistry.getDepositInfo` returns `(uint256 stake, uint32 unstakeDelaySec, uint64
  withdrawTime)`, and a withdrawal in progress disqualifies the stake (STAKING-010). Our interface had a
  different shape until we checked.
- Per the sidecar's own docs, keyed txs are exempt from the per-sender cap of 4, but pending gas must fit
  the **payer's balance**. A self-paying account needs at least 12 × `maxCost` to hold 12 pending
  liquidations. (To confirm live in the crash scene.)
- Frame receipts come back through `eth_getTransactionReceipt` with per-frame `frameReceipts[i].status`
  (as the workshop reads them).

## 3. EXO-010, scoped

**The problem.** ERC-7562-style reputation counts every admitted-then-dropped transaction as a miss
against its sender: `max_seen = ⌊seen/10⌋` against `included`, throttled at +10, banned at +50. A
liquidation carrier is invalidated **by design** when the market moves: a newer round arrives, or the
borrower repays first. A market-wide bounce therefore throttles the honest carrier at exactly the moment
it is needed.

**The proposal (EXO-010).** A pending tx invalidated by an *outside* state change (the cited round
superseded, or the position no longer liquidatable) decrements `seen` instead of counting a miss. Keyed
replacement already adds nothing to `seen` (REPUTATION-040).

**What we claim, and what we don't.**

- **Claimed (local test):** in a replay of a 150-pending bounce through the sidecar's counting rules
  (`kit/src/sim/exo010.ts`), the baseline rule ends **THROTTLED** and EXO-010 stays **ACTIVE**. The rules
  modelled are listed at the top of that file; the chart is on the dashboard.
- **Measured (written, not run):** `just reputation before` → `just scene crash` → `just reputation
  after` records the account's real `opsSeen` / `opsIncluded` / status on the devnet, plotted beside the
  simulation. On anvil the counters come from the mock node and are labelled as such.
- **Not claimed:** that EXO-010 is safe against an attacker who triggers outside state changes to
  launder misses. Telling "invalidated by an outside change" apart from "the sender's own fault" needs
  the node to re-check the specific predicate (the round moved, or the position became healthy). That
  check is the open design question, and it is out of scope here.

## 4. Status and links

- Phase A on the devnet (`just gate-a`), **on devnet**: keyless self-paid liquidation
  [`0x913762f6…fe56`](https://explorer.altmempool.wtf/tx/0x913762f6f96a17f2063a060c3b1ebfbd6c6af70c1f2a9e5a94511ea81440fe56?node=https%3A%2F%2Faltmempool.forshtat.com%2Frpc),
  included in block 2865: type `0x6` from the AutolysisAccount `0x91233f8dEf56AC435a7F658AC8F96C591939cd40`,
  both frames `0x1`, `LiquidationOk`. VERIFY gas from simulate: 94,168 (outside reads, chosen) and 71,892
  (storage-only). The canonical mempool rejected the same tx: `Invalid params: Frame transaction
  validation-prefix simulation failed: StorageReadNonSender`.
- Crash, **on devnet**: 12 positions (0.25 ETH each) liquidatable in one round, each sent to both
  mempools.
  - Canonical mempool: **0 of 12** accepted (`StorageReadNonSender`).
  - Alt mempool: **12 of 12** included, all `LiquidationOk`. Eleven landed in blocks 3576 / 3579 / 3581
    (4 / 4 / 3 per block from one account on separate nonce keys), e.g.
    [`0xf502d8c4…f94d`](https://explorer.altmempool.wtf/tx/0xf502d8c4a655e1b9538505a666f87c583ebfa11e4a7eda310d66db667c08f94d?node=https%3A%2F%2Faltmempool.forshtat.com%2Frpc).
  - The 12th send got no response from the RPC (`fetch failed`) and never reached a sidecar. It was resent
    on a fresh round and included in block 6776:
    [`0xdf40beb3…b1d0`](https://explorer.altmempool.wtf/tx/0xdf40beb38571731a96de0aa328f6669ac9b9590c6079f95934afb4a2478bb1d0?node=https%3A%2F%2Faltmempool.forshtat.com%2Frpc).
  - Every hash is in `deployments/1337.json` (`scenes.crash`) and the README table.
- Attacks, **on devnet**: 5 of 5 rejected at admission, each with the exact text recorded in
  `scenes.attacks`.
  - Our VERIFY rejected three: wrong selector → `Rejected(EXEC_SELECTOR)`; fee over cap →
    `Rejected(FEE_CAP)`; stale round → `StaleRound()`.
  - The sidecar's structural checks rejected two before VERIFY ran: the appended key (`nonceKeys must be
    strictly increasing`) and frame 0 in DEFAULT mode (`frame transaction validation prefix not
    recognized`).
- Replacement, **not demonstrated**: the lower-fee tx was rejected at admission (`validation frame 0:
  reverted … "approve failed"`). The +10% tx on the same key and sequence was admitted and included
  ([`0xf793ccd2…4880`](https://explorer.altmempool.wtf/tx/0xf793ccd21e141aa3aa3129f512590997fb7679a3506598c99d575c46c48f4880?node=https%3A%2F%2Faltmempool.forshtat.com%2Frpc)).
  The cause of the first rejection could not be reproduced afterwards.
- Everything local and forked is reproducible with `just demo-local` and `just fork-c2`.
