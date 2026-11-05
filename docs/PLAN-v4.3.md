# Autolysis build plan v4.3

> **Superseded in part by [`docs/DEVNET.md`](./DEVNET.md) (Nov 5).** The devnet is now real and its facts
> (endpoints, `MAX_VERIFY_GAS = 100,000` with no 1M staked allowance, `NaiveStakingRegistry` + minStake
> 0.01 ETH, ARBITRARY-by-default signatures, predeployed Uniswap v4 on chain 1337, the probe rewrite on
> `ethrex_simulateFrameTransaction`) override the assumptions below wherever they differ. Biggest change:
> deploy the BackstopHook against the **predeployed** v4 PoolManager on the devnet (EF + Uniswap proofs on
> one chain), and VERIFY must use the storage-only path to fit 100k.

Written Wed Nov 4, 22:10 IST. Submission Sat Nov 7, 09:00 IST. Replaces the build order in REVIEW-3;
its R1-R5 items still apply. Three environments prove three tracks:

- A. Devnet chain 1337 (ethrex eip8141-tracer + ERC-8421 sidecar): EF track. Depends on the frame devnet.
- B. Fork of Unichain mainnet (130): 1inch (real Aqua fill via our gated SwapVM router) + Uniswap
  (liquidation through the real v4 PoolManager). No frame devnet needed.
- C. Unichain Sepolia (1301): Uniswap public explorer links.

Official addresses (verify each with `cast code` before use):

| | Unichain (130) | Unichain Sepolia (1301) |
|---|---|---|
| v4 PoolManager | 0x1f98400000000000000000000000000000000004 | 0x00b036b58a818b1bc34d502d3fe730db729e62ac |
| v4 PositionManager | 0x4529a01c7a0410167c5740c487a8de60232617bf | 0xf969aee60879c54baaed9f3ed26147db216fd664 |
| Aqua registry | 0x1111113ccf1426a8e30e2bff5e005d929bf6a90a | not deployed |
| AquaSwapVMRouter v1.0.2 (reference) | 0x111111338c5091e8440b67b168bae16a668ac0de | not deployed |
| WETH | 0x4200000000000000000000000000000000000006 | same |
| USDC | verify with cast; else MockUSDC | MockUSDC |

Fork RPC: https://mainnet.unichain.org

Rules: proof beats features; label every status line (on devnet / on fork / on Sepolia / local test /
mock only / written, not run); never call an unconfirmed RPC/contract/interface (TODO(ask: …) if
unknown); commit after each green exit; freeze Friday 22:00 IST.

(Full plan text is the user's message of Nov 4 22:10; this copy is the working reference. W1=EF/devnet,
W2=1inch/fork, W3=Uniswap/fork+Sepolia, W4=safety, W5=demo/submission.)
