# app/

- `dashboard/` — the D3 dashboard (one page). `just dashboard` serves it on http://127.0.0.1:5173 for
  `CHAIN_ID` (default 1337) through `RPC_URL` (default the devnet gateway); `just demo-local` runs the
  whole flow on anvil + the mock frame node and keeps the dashboard up. It reads
  `deployments/<chainId>.json` (gate-a, scenes, reputation snapshots) and the chain (positions, receipts,
  logs) and shows: crash button + positions, canonical-vs-alt texts, each tx's lifecycle, net saved vs a
  classic liquidation, and EXO-010 simulated beside measured.
- `server.mjs` — the dashboard's local server (127.0.0.1 only): static files, the deployment record, an
  RPC proxy, and `POST /api/crash`, which runs `just scene crash` with the server's own `.env` key.
- `lab-exo010.html` — the earlier stand-alone EXO-010 chart (simulation only).
