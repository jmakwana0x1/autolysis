#!/usr/bin/env node
// Produces the EXO-010 with/without chart data: baseline vs proposed max_seen across a bounce, with the
// throttle line. Writes kit/out/exo010.json (used by just sim) and prints the end state.
import { writeFileSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { simulate, bounceTrace, THROTTLE_MARGIN } from "../src/sim/exo010.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const pending = Number(process.env.PENDING ?? 150);
const { series, baselineStatus, proposedStatus, baseline, proposed } = simulate(bounceTrace(pending));
mkdirSync(join(root, "out"), { recursive: true });
writeFileSync(
  join(root, "out/exo010.json"),
  JSON.stringify({ pending, throttleMargin: THROTTLE_MARGIN, baselineStatus, proposedStatus, baseline, proposed, series }, null, 2),
);
console.log(`EXO-010 (pending=${pending}): baseline ${baselineStatus} (max_seen ${Math.floor(baseline.seen / 10)}) vs proposed ${proposedStatus} (max_seen ${Math.floor(proposed.seen / 10)}); throttle at included+${THROTTLE_MARGIN}`);
