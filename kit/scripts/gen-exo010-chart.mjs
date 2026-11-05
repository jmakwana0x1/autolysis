#!/usr/bin/env node
// Produces the EXO-010 with/without chart data for the EF write-up and the Lab page.
// Writes kit/out/exo010.json: the reputation series under baseline vs proposed rules for a bounce.
import { writeFileSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { simulate, bounceTrace, THROTTLE } from "../src/sim/exo010.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const pending = Number(process.env.PENDING ?? 150);
const { series, baselineFinal, proposedFinal } = simulate(bounceTrace(pending));
mkdirSync(join(root, "out"), { recursive: true });
writeFileSync(
  join(root, "out/exo010.json"),
  JSON.stringify({ pending, throttle: THROTTLE, baselineFinal, proposedFinal, series }, null, 2),
);
console.log(`EXO-010 (pending=${pending}): baseline ${baselineFinal.toFixed(3)} vs proposed ${proposedFinal.toFixed(3)} (throttle ${THROTTLE})`);
