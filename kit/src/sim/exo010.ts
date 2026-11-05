// EXO-010 simulator: replays crash and bounce traces through the ERC-8421 reputation rules, with and
// without the proposed rule, producing reproducible with/without series for the EF write-up.
//
// Reputation model (draft ERC-8421 as the sidecar implements it):
//   - Each carrier has a reputation score in [0, 1], starting at START.
//   - A liquidation the carrier gets INCLUDED raises reputation toward 1.
//   - A liquidation the carrier had pending that becomes INVALID (price recovered / rescued) is "seen
//     but not included". Under the BASELINE rule every such miss is penalized. Under the PROPOSED rule,
//     a miss caused by a price move that invalidated the whole pending set (a bounce) is forgiven, so
//     honest carriers are not throttled for the market recovering.
//   - A keyed REPLACEMENT (same key, higher fee, new round) must not itself move reputation.
// A carrier below THROTTLE is rate-limited by the mempool.

export const START = 0.8;
export const THROTTLE = 0.5;
const UP = 0.02; // reward per inclusion
const DOWN = 0.05; // penalty per non-forgiven miss

export type Event =
  | { t: number; kind: "included" }
  | { t: number; kind: "miss"; bounce: boolean } // pending invalidated; bounce = market-wide recovery
  | { t: number; kind: "replacement" };

export type Point = { t: number; baseline: number; proposed: number };

function clamp(x: number): number {
  return x < 0 ? 0 : x > 1 ? 1 : x;
}

export function simulate(trace: Event[]): { series: Point[]; baselineFinal: number; proposedFinal: number } {
  let baseline = START;
  let proposed = START;
  const series: Point[] = [{ t: 0, baseline, proposed }];
  for (const e of trace) {
    switch (e.kind) {
      case "included":
        baseline = clamp(baseline + UP);
        proposed = clamp(proposed + UP);
        break;
      case "miss":
        baseline = clamp(baseline - DOWN); // baseline penalizes every miss
        if (!e.bounce) proposed = clamp(proposed - DOWN); // proposed forgives bounce-caused misses
        break;
      case "replacement":
        // no reputation change under either rule
        break;
    }
    series.push({ t: e.t, baseline, proposed });
  }
  return { series, baselineFinal: baseline, proposedFinal: proposed };
}

/** Whether a score is above the throttle line at every point (honest carriers should stay above). */
export function throttledAt(series: Point[], which: "baseline" | "proposed"): number[] {
  return series.filter((p) => p[which] < THROTTLE).map((p) => p.t);
}

/** A canonical oracle-bounce trace: a crash triggers many pending liquidations, then the price bounces
 *  back and invalidates them all at once (the EXO-010 scenario in the plan). */
export function bounceTrace(pendingDuringCrash: number): Event[] {
  const trace: Event[] = [];
  let t = 1;
  // during the crash a few liquidations are legitimately included
  for (let i = 0; i < 3; i++) trace.push({ t: t++, kind: "included" });
  // then the price bounces: every remaining pending liquidation misses, all from the same move
  for (let i = 0; i < pendingDuringCrash; i++) trace.push({ t: t++, kind: "miss", bounce: true });
  return trace;
}

/** A replacement storm: the same liquidation is rebroadcast with fee bumps across rounds. */
export function replacementTrace(rounds: number): Event[] {
  const trace: Event[] = [];
  let t = 1;
  for (let i = 0; i < rounds; i++) trace.push({ t: t++, kind: "replacement" });
  trace.push({ t: t++, kind: "included" });
  return trace;
}
