// EXO-010 simulator: replays crash/bounce traces through the ERC-8421 reputation rules, under the
// baseline rule and the proposed EXO-010 rule, producing reproducible with/without series.
//
// Rules modeled (as the sidecar implements them):
//   - Two integer counters per sender: `seen` and `included`.
//   - A liquidation the carrier gets INCLUDED: seen++ and included++.
//   - A liquidation SEEN but not included (a miss): seen++ (baseline).
//   - REPUTATION-040: a keyed REPLACEMENT adds nothing to `seen`.
//   - Hourly DECAY: on each hour boundary, seen = floor(seen*23/24), included = floor(included*23/24).
//   - max_seen = floor(seen/10). Status from max_seen vs included:
//       ACTIVE     if max_seen <= included + 10
//       THROTTLED  if max_seen <= included + 50   (rate-limited to 4 txs/block)
//       BANNED     otherwise
//   - REPUTATION-330: a staked sender absorbs other entities' failures (their misses don't raise its
//     seen). Modeled by the `staked` flag: a miss marked `external` does not count against a staked
//     sender.
//   - EXO-010 (proposed): a tx invalidated by an outside state change (the round moved, the borrower
//     repaid) decrements `seen` instead of counting as a miss, so a market-wide bounce does not throttle
//     honest carriers.

export type Status = "ACTIVE" | "THROTTLED" | "BANNED";
export const ACTIVE_MARGIN = 10;
export const THROTTLE_MARGIN = 50;

export type Event =
  | { kind: "included" }
  | { kind: "miss"; external: boolean } // external = invalidated by an outside state change (a bounce)
  | { kind: "replacement" }
  | { kind: "hour" }; // an hour boundary: apply decay

type Counters = { seen: number; included: number };

function decay(c: Counters): Counters {
  return { seen: Math.floor((c.seen * 23) / 24), included: Math.floor((c.included * 23) / 24) };
}

function maxSeen(c: Counters): number {
  return Math.floor(c.seen / 10);
}

export function status(c: Counters): Status {
  const ms = maxSeen(c);
  if (ms <= c.included + ACTIVE_MARGIN) return "ACTIVE";
  if (ms <= c.included + THROTTLE_MARGIN) return "THROTTLED";
  return "BANNED";
}

export type Point = { t: number; baselineMaxSeen: number; proposedMaxSeen: number; throttleLine: number };

/** Run a trace under both rules. `staked` applies REPUTATION-330 to external misses. */
export function simulate(trace: Event[], opts: { staked?: boolean } = {}): {
  series: Point[];
  baseline: Counters;
  proposed: Counters;
  baselineStatus: Status;
  proposedStatus: Status;
} {
  let baseline: Counters = { seen: 0, included: 0 };
  let proposed: Counters = { seen: 0, included: 0 };
  const staked = opts.staked ?? false;
  const series: Point[] = [pt(0, baseline, proposed)];
  trace.forEach((e, i) => {
    switch (e.kind) {
      case "included":
        baseline = { seen: baseline.seen + 1, included: baseline.included + 1 };
        proposed = { seen: proposed.seen + 1, included: proposed.included + 1 };
        break;
      case "miss":
        // Baseline: every miss raises seen (unless a staked sender absorbs an external failure).
        if (!(staked && e.external)) baseline = { ...baseline, seen: baseline.seen + 1 };
        // Proposed: an outside-caused miss decrements seen (EXO-010); a genuine miss still raises it.
        if (e.external) proposed = { ...proposed, seen: Math.max(0, proposed.seen - 1) };
        else proposed = { ...proposed, seen: proposed.seen + 1 };
        break;
      case "replacement":
        // REPUTATION-040: no counter change under either rule.
        break;
      case "hour":
        baseline = decay(baseline);
        proposed = decay(proposed);
        break;
    }
    series.push(pt(i + 1, baseline, proposed));
  });
  return {
    series,
    baseline,
    proposed,
    baselineStatus: status(baseline),
    proposedStatus: status(proposed),
  };
}

function pt(t: number, b: Counters, p: Counters): Point {
  return {
    t,
    baselineMaxSeen: maxSeen(b),
    proposedMaxSeen: maxSeen(p),
    throttleLine: b.included + THROTTLE_MARGIN,
  };
}

/** The canonical oracle-bounce trace: a crash includes a few liquidations, then the price bounces and
 *  invalidates every remaining pending liquidation at once (external misses). */
export function bounceTrace(pendingDuringCrash: number): Event[] {
  const trace: Event[] = [];
  for (let i = 0; i < 3; i++) trace.push({ kind: "included" });
  for (let i = 0; i < pendingDuringCrash; i++) trace.push({ kind: "miss", external: true });
  return trace;
}

/** A replacement storm: the same liquidation rebroadcast with fee bumps, then one inclusion. */
export function replacementTrace(rounds: number): Event[] {
  const trace: Event[] = [];
  for (let i = 0; i < rounds; i++) trace.push({ kind: "replacement" });
  trace.push({ kind: "included" });
  return trace;
}
