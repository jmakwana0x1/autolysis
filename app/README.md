# Autolysis app

Four pages, each number sourced from on-chain events on the devnet (addresses from
`deployments/1337.json`), except the Lab's EXO-010 panel, which is reproducible simulator output.

| Page | Shows |
| --- | --- |
| Borrow | Position health, auto-deleverage and rescue controls |
| Backstop | Coverage, shared-liquidity ratio, maker reliability |
| Lab | Tank and reputation gauges, attack buttons, and the EXO-010 with/without chart |
| Rescue | One-click repay to invalidate a pending liquidation |

`lab-exo010.html` is the standalone Lab chart (EXO-010): it embeds the output of
`kit/src/sim/exo010.ts` replaying `bounceTrace(150)`. Regenerate the embedded data with
`just sim`. The Borrow / Backstop / Rescue pages render against a live devnet and are wired through
the kit; without `RPC_URL` they have no data to show.
