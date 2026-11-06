// Autolysis dashboard (D3). Reads deployments/<chainId>.json through the local server and the chain
// through its /rpc proxy; decodes receipts and logs by hand (topics precomputed with `cast keccak`).
const TOPIC = {
  Liquidated: "0xaba55d211ce7fea603f68bc4334b6a5571bebe744d468ad609cdf01fc3b64d27",
  Waterfall: "0x06290c4349681fec5fc2d5e6f6574c9f8cf72ea4165f59cc2b4acbf87d031524",
  LiquidationOk: "0x5fb45205d257af9878704f826d7ba2459f0162d7fd7e5ba8838922682b1af4f9",
  LiquidationFailed: "0x28746e5ca2f7423427753de456e64f971692f3579fc516891e311518dd9a7ffb",
  SwapVMFilled: "0x319252a01cb7d4aeae566414c66811f41b26bf6e133a87f3e8509c550164fffd",
};
const SEL = { positions: "0x99fbab88", healthFactor: "0xbc71054e", getRound: "0x8f1327c0" };
const WAD = 10n ** 18n;
const CLASSIC_BONUS_BPS = 500n; // AutolysisMarket.CLASSIC_BONUS_BPS

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const short = (h) => (h && h.length > 18 ? `${h.slice(0, 10)}…${h.slice(-6)}` : h ?? "");
const words = (data) => (data ?? "0x").slice(2).match(/.{64}/g)?.map((w) => BigInt("0x" + w)) ?? [];
const fmt = (wad, dp = 4) => {
  if (wad === null || wad === undefined) return "n/a";
  const neg = wad < 0n;
  const v = neg ? -wad : wad;
  const s = `${v / WAD}.${(v % WAD).toString().padStart(18, "0").slice(0, dp)}`;
  return (neg ? "−" : "") + s;
};
const chip = (cls, text, title = "") => `<span class="chip ${cls}" title="${esc(title)}"><span class="dot"></span>${esc(text)}</span>`;

let rpcId = 0;
async function rpc(method, params = []) {
  const r = await fetch("/rpc", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method, params }) });
  const j = await r.json();
  if (j.error) throw new Error(`${method}: ${j.error.message}`);
  return j.result;
}
const uintArg = (n) => BigInt(n).toString(16).padStart(64, "0");
const call = async (to, sel, arg) => words(await rpc("eth_call", [{ to, data: sel + (arg === undefined ? "" : uintArg(arg)) }, "latest"]));

// ------------------------------------------------------------------------------------------- load

async function load() {
  const [config, dep, exo] = await Promise.all([
    fetch("/data/config").then((r) => r.json()),
    fetch("/data/deployment").then((r) => (r.ok ? r.json() : null)),
    fetch("/data/exo010").then((r) => r.json()).catch(() => null),
  ]);
  return { config, dep, exo };
}

async function liquidationsOf(dep) {
  const out = [];
  const L = dep?.gateA?.liquidation;
  if (L?.hash) out.push({ label: "Gate A", positionId: L.positionId, hash: L.hash, admitted: true, mockable: true });
  for (const it of dep?.scenes?.crash?.items ?? []) {
    const hash = it.alt?.hash ?? (it.canonical?.accepted ? safeResult(it.canonical.responseText) : null);
    out.push({ label: "Crash", positionId: it.positionId, hash, admitted: !!it.alt?.admitted, altError: it.alt?.error });
  }
  const c = dep?.contracts ?? {};
  await Promise.all(
    out.map(async (x) => {
      if (!x.hash) return;
      try {
        x.receipt = await rpc("eth_getTransactionReceipt", [x.hash]);
        x.status = await rpc("skandha_frameTransactionStatus", [x.hash]).catch(() => null);
      } catch (e) {
        x.error = e.message;
      }
      const logs = x.receipt?.logs ?? [];
      const is = (l, addr, t) => l.address?.toLowerCase() === addr?.toLowerCase() && l.topics?.[0] === t;
      const liq = logs.find((l) => is(l, c.AutolysisMarket, TOPIC.Liquidated));
      if (liq) {
        const [roundId, debtRepaid, collateralSold, fee] = words(liq.data);
        x.liq = { roundId, debtRepaid, collateralSold, fee };
        const [price] = await call(c.RoundFeed, SEL.getRound, roundId).catch(() => [null]);
        x.liq.price = price;
      }
      const wf = logs.find((l) => is(l, c.BackstopHook, TOPIC.Waterfall));
      if (wf) {
        const [t1, t2, t3] = words(wf.data);
        x.tiers = { t1, t2, t3 };
      }
      x.swapvm = logs.filter((l) => is(l, c.BackstopHook, TOPIC.SwapVMFilled)).length;
      x.outcome = logs.some((l) => is(l, c.AutolysisAccount, TOPIC.LiquidationOk))
        ? "LiquidationOk"
        : logs.some((l) => is(l, c.AutolysisAccount, TOPIC.LiquidationFailed))
          ? "LiquidationFailed"
          : null;
    }),
  );
  return out;
}

function safeResult(text) {
  try {
    return JSON.parse(text).result ?? null;
  } catch {
    return null;
  }
}

// ----------------------------------------------------------------------------------------- render

function renderMeta(config, dep) {
  const mock = config.chainId !== 1337 ? " · local chain (frame RPCs mocked)" : "";
  $("meta").innerHTML = `chain ${config.chainId} · rpc ${esc(config.rpcLabel)}${esc(mock)} · ${dep?.gateA?.updatedAt ? "recorded " + esc(new Date(dep.gateA.updatedAt).toLocaleString()) : "no record"}`;
}

function renderTiles(dep, liqs, saved) {
  const crash = dep?.scenes?.crash?.summary;
  const gate = dep?.gateA?.result === "passed";
  const tiles = [
    { label: "Gate A", value: gate ? "Passed" : dep?.gateA?.failed ? "Stopped" : "Not run", note: gate ? `VERIFY path: ${dep.gateA.verify?.chosen}` : dep?.gateA?.failed ? `at ${dep.gateA.failed.step}` : "run just gate-a" },
    { label: "Alt mempool: included", value: crash ? `${crash.liquidationOk} / ${crash.positions}` : "–", note: "crash scene, LiquidationOk receipts" },
    { label: "Canonical mempool: accepted", value: crash ? `${crash.canonicalAccepted} / ${crash.positions}` : "–", note: "same txs via eth_sendRawTransaction" },
    { label: "Net saved vs classic", value: liqs.some((l) => l.liq) ? fmt(saved, 4) : "–", note: "USDC, over all recorded liquidations" },
  ];
  $("tiles").innerHTML = tiles.map((t) => `<div class="tile"><div class="label">${esc(t.label)}</div><div class="value">${esc(t.value)}</div><div class="note">${esc(t.note)}</div></div>`).join("");
}

async function renderPositions(dep) {
  const ids = dep?.scenes?.crash?.positions ?? dep?.gateA?.positions ?? [];
  const tbl = $("positions");
  if (!ids.length) {
    tbl.innerHTML = `<tr><td class="empty">No positions yet: run the crash scene.</td></tr>`;
    return;
  }
  const market = dep.contracts.AutolysisMarket;
  const rows = await Promise.all(
    ids.map(async (id) => {
      try {
        const [, collateral, debt, liquidations] = await call(market, SEL.positions, id);
        const [hf] = await call(market, SEL.healthFactor, id);
        return { id, collateral, debt, liquidations, hf };
      } catch (e) {
        return { id, error: e.message };
      }
    }),
  );
  tbl.innerHTML =
    `<thead><tr><th>Position</th><th class="num">Collateral (WETH)</th><th class="num">Debt (USDC)</th><th class="num">Health factor</th><th class="num">Self-liquidations</th><th>State</th></tr></thead><tbody>` +
    rows
      .map((r) =>
        r.error
          ? `<tr><td>#${esc(r.id)}</td><td colspan="5" class="bad">${esc(r.error)}</td></tr>`
          : `<tr><td>#${esc(r.id)}</td><td class="num">${fmt(r.collateral)}</td><td class="num">${fmt(r.debt)}</td><td class="num">${fmt(r.hf, 3)}</td><td class="num">${r.liquidations}</td><td>${r.hf < WAD ? chip("bad", "Unhealthy") : chip("ok", "Healthy")}</td></tr>`,
      )
      .join("") +
    "</tbody>";
}

function renderCva(dep) {
  const g = dep?.gateA?.canonical;
  const crash = dep?.scenes?.crash;
  let html = "";
  if (g) {
    html += `<p class="sub" style="margin-bottom:6px"><strong>Gate A</strong>, position #${esc(g.positionId)} on the ${esc(g.path ?? "?")} VERIFY path: canonical ${g.accepted ? chip("ok", "Accepted") : chip("bad", "Rejected")}, alt ${dep.gateA.liquidation?.hash ? chip("ok", "Admitted") : chip("none", "Not sent")}</p><code class="text">${esc(g.responseText)}</code>`;
  }
  if (crash?.items?.length) {
    const s = crash.summary ?? {};
    html += `<p class="sub" style="margin:14px 0 6px"><strong>Crash</strong>: canonical accepted ${s.canonicalAccepted ?? "?"} / ${s.positions ?? "?"}, alt admitted ${s.altAdmitted ?? "?"} / ${s.positions ?? "?"}, included ${s.included ?? "?"} / ${s.positions ?? "?"}</p>`;
    html += `<div class="scroll"><table><thead><tr><th>Position</th><th>Canonical (eth_sendRawTransaction)</th><th>Alt (eth_sendFrameTransaction)</th></tr></thead><tbody>${crash.items
      .map((it) => `<tr><td>#${esc(it.positionId)}</td><td><code class="text">${esc(it.canonical?.responseText)}</code></td><td>${it.alt?.admitted ? `${chip("ok", "Admitted")} <code class="hash">${esc(it.alt.hash)}</code>` : `<code class="text">${esc(it.alt?.error)}</code>`}</td></tr>`)
      .join("")}</tbody></table></div>`;
  }
  $("cva").innerHTML = html || `<p class="empty">Nothing recorded yet: run just gate-a.</p>`;
}

function renderLifecycle(liqs, config) {
  const tbl = $("lifecycle");
  if (!liqs.length) {
    tbl.innerHTML = `<tr><td class="empty">No liquidations recorded yet.</td></tr>`;
    return;
  }
  const step = (ok, label, title) => (ok === true ? chip("ok", label, title) : ok === false ? chip("bad", label, title) : chip("none", label, title));
  tbl.innerHTML =
    `<thead><tr><th>Tx</th><th>Position</th><th>Lifecycle</th><th>Outcome</th></tr></thead><tbody>` +
    liqs
      .map((x) => {
        const fr = x.receipt?.frameReceipts ?? [];
        const mock = fr[0]?.mock ? " (mock)" : "";
        const verify = x.receipt ? fr[0]?.status === "0x1" : x.hash ? null : false;
        const sender = x.receipt ? fr[1]?.status === "0x1" : null;
        const tier = x.tiers
          ? x.tiers.t1 > 0n
            ? `Tier 1 Aqua ${fmt(x.tiers.t1, 2)}`
            : x.tiers.t2 > 0n
              ? `Tier 2 house ${fmt(x.tiers.t2, 2)}`
              : x.tiers.t3 > 0n
                ? "Tier 3 pool"
                : "No tier"
          : "Tier ?";
        const gas = x.liq ? x.liq.fee > 0n : null;
        const st = typeof x.status === "object" && x.status ? x.status.status : null;
        return `<tr><td>${x.hash ? `<code class="hash" title="${esc(x.hash)}">${esc(short(x.hash))}</code><br><span class="label-mock">${esc(x.label)} · search in ${esc(config.explorerUrl)}</span>` : `<span class="empty">not sent</span>`}</td>
          <td>#${esc(x.positionId)}</td>
          <td><div class="steps">${step(verify, "VERIFY" + mock, "frameReceipts[0].status")}${step(x.admitted, `Admitted${st ? " · " + st : ""}`, x.altError ?? "eth_sendFrameTransaction")}${step(sender, "SENDER", "frameReceipts[1].status")}${step(x.tiers ? true : null, tier, "BackstopHook Waterfall log")}${step(gas, gas ? `Gas refilled ${fmt(x.liq.fee, 6)} ETH` : "Gas refill", "Liquidated.fee: collateral unwrapped to the account")}</div>${x.error ? `<div class="bad">${esc(x.error)}</div>` : ""}</td>
          <td>${x.outcome === "LiquidationOk" ? chip("ok", "LiquidationOk") : x.outcome ? chip("bad", x.outcome) : chip("wait", x.receipt ? "no outcome log" : "pending")}</td></tr>`;
      })
      .join("") +
    "</tbody>";
}

/** Per liquidation: classic cost = 5% bonus on the debt repaid; Autolysis cost = sale haircut vs the
 *  cited price + the gas fee billed in collateral. Saved = classic − Autolysis (USDC, WAD). */
function renderNet(liqs) {
  $("formula").innerHTML =
    "Model, per liquidation: <strong>classic cost</strong> = 5% liquidation bonus × debt repaid (the D1 fallback's bonus); <strong>Autolysis cost</strong> = (collateral sold × cited price − debt repaid) + gas fee × cited price. Saved = classic − Autolysis, in USDC.";
  const rows = liqs.filter((x) => x.liq && x.liq.price);
  let total = 0n;
  const body = rows
    .map((x) => {
      const { debtRepaid: D, collateralSold: S, fee: F, price: P } = x.liq;
      const haircut = (S * P) / WAD - D;
      const gas = (F * P) / WAD;
      const classic = (D * CLASSIC_BONUS_BPS) / 10_000n;
      const saved = classic - haircut - gas;
      total += saved;
      return `<tr><td>#${esc(x.positionId)}</td><td class="num">${fmt(D)}</td><td class="num">${fmt(S)}</td><td class="num">${fmt(P, 3)}</td><td class="num">${fmt(classic)}</td><td class="num">${fmt(haircut)}</td><td class="num">${fmt(gas, 6)}</td><td class="num"><strong>${fmt(saved)}</strong></td></tr>`;
    })
    .join("");
  $("net").innerHTML = rows.length
    ? `<thead><tr><th>Position</th><th class="num">Debt repaid</th><th class="num">Collateral sold</th><th class="num">Cited price</th><th class="num">Classic cost</th><th class="num">Sale haircut</th><th class="num">Gas fee</th><th class="num">Saved</th></tr></thead><tbody>${body}<tr><td colspan="7"><strong>Total</strong></td><td class="num"><strong>${fmt(total)}</strong></td></tr></tbody>`
    : `<tr><td class="empty">No included liquidations to price yet.</td></tr>`;
  return total;
}

// ------------------------------------------------------------------------------------------ chart

function lineChart(el, { xs, xLabel, series, markers = false }) {
  const W = 600, H = 250, m = { l: 40, r: 34, t: 10, b: 26 };
  const iw = W - m.l - m.r, ih = H - m.t - m.b;
  const n = xs.length;
  const ymax = Math.max(1, ...series.flatMap((s) => s.values.filter((v) => v !== null))) * 1.1;
  const x = (i) => m.l + (n <= 1 ? iw / 2 : (i / (n - 1)) * iw);
  const y = (v) => m.t + ih - (v / ymax) * ih;
  const ticks = 4;
  let svg = `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(series.map((s) => s.name).join(", "))}">`;
  for (let k = 0; k <= ticks; k++) {
    const v = (ymax / ticks) * k;
    svg += `<line x1="${m.l}" x2="${W - m.r}" y1="${y(v)}" y2="${y(v)}" stroke="var(--grid)" stroke-width="1"/><text x="${m.l - 6}" y="${y(v) + 4}" text-anchor="end" font-size="11" fill="var(--text-muted)">${Math.round(v)}</text>`;
  }
  const step = Math.max(1, Math.ceil(n / 6));
  for (let i = 0; i < n; i += step) svg += `<text x="${x(i)}" y="${H - 10}" text-anchor="middle" font-size="11" fill="var(--text-muted)">${esc(xs[i])}</text>`;
  for (const s of series) {
    const pts = s.values.map((v, i) => (v === null ? null : `${x(i)},${y(v)}`)).filter(Boolean);
    const color = s.dash ? "var(--text-muted)" : s.color;
    svg += `<polyline fill="none" stroke="${color}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round" ${s.dash ? 'stroke-dasharray="5 4"' : ""} points="${pts.join(" ")}"/>`;
    if (markers && !s.dash) s.values.forEach((v, i) => v !== null && (svg += `<circle cx="${x(i)}" cy="${y(v)}" r="4.5" fill="${color}" stroke="var(--surface-1)" stroke-width="2"/>`));
  }
  svg += `<line id="xh" x1="0" x2="0" y1="${m.t}" y2="${m.t + ih}" stroke="var(--text-muted)" stroke-width="1" visibility="hidden"/>`;
  svg += `<rect x="${m.l}" y="${m.t}" width="${iw}" height="${ih}" fill="transparent" class="hit"/></svg>`;
  const legend = `<div class="legend">${series.map((s) => `<span><span class="sw ${s.dash ? "dash" : ""}" style="background:${s.color}"></span>${esc(s.name)}</span>`).join("")}</div>`;
  el.innerHTML = legend + svg + `<div class="label-mock" style="text-align:right">x: ${esc(xLabel)}</div><div class="tip"></div>`;
  const svgEl = el.querySelector("svg"), tip = el.querySelector(".tip"), xh = el.querySelector("#xh");
  el.querySelector(".hit").addEventListener("pointermove", (ev) => {
    const r = svgEl.getBoundingClientRect();
    const px = ((ev.clientX - r.left) / r.width) * W;
    const i = Math.max(0, Math.min(n - 1, Math.round(((px - m.l) / iw) * (n - 1))));
    xh.setAttribute("x1", x(i));
    xh.setAttribute("x2", x(i));
    xh.setAttribute("visibility", "visible");
    tip.style.display = "block";
    tip.innerHTML = `<strong>${esc(xLabel)} ${esc(xs[i])}</strong><br>` + series.map((s) => `${esc(s.name)}: ${s.values[i] ?? "–"}`).join("<br>");
    const left = (x(i) / W) * r.width;
    tip.style.left = `${Math.min(left + 12, r.width - tip.offsetWidth - 4)}px`;
    tip.style.top = `${40}px`;
  });
  el.querySelector(".hit").addEventListener("pointerleave", () => {
    tip.style.display = "none";
    xh.setAttribute("visibility", "hidden");
  });
}

function table(el, head, rows) {
  el.innerHTML = `<table><thead><tr>${head.map((h) => `<th>${esc(h)}</th>`).join("")}</tr></thead><tbody>${rows.map((r) => `<tr>${r.map((c) => `<td class="num">${esc(c)}</td>`).join("")}</tr>`).join("")}</tbody></table>`;
}

function renderExo(exo, dep, config) {
  if (exo?.series?.length) {
    const s = exo.series;
    lineChart($("sim-chart"), {
      xs: s.map((p) => p.t),
      xLabel: "simulated event (included, miss, replacement, hour)",
      series: [
        { name: "max_seen, baseline rule (live)", color: "var(--series-1)", values: s.map((p) => p.baselineMaxSeen) },
        { name: "max_seen, EXO-010", color: "var(--series-2)", values: s.map((p) => p.proposedMaxSeen) },
        { name: "throttle line (included + 10)", dash: true, color: "var(--text-muted)", values: s.map((p) => p.throttleLine) },
      ],
    });
    table($("sim-table"), ["event", "baseline max_seen", "EXO-010 max_seen", "throttle line"], s.map((p) => [p.t, p.baselineMaxSeen, p.proposedMaxSeen, p.throttleLine]));
  } else {
    $("sim-chart").innerHTML = `<p class="empty">No simulation data: run just sim.</p>`;
  }
  const snaps = dep?.reputation?.snapshots ?? [];
  $("measured-src").textContent = snaps.length ? (config.chainId === 1337 ? "(live devnet)" : "(local chain: mock node counters)") : "";
  if (snaps.length) {
    const maxSeen = snaps.map((p) => (p.opsSeen === null ? null : Math.floor(p.opsSeen / 10)));
    lineChart($("meas-chart"), {
      xs: snaps.map((p) => p.label),
      xLabel: "reputation snapshot",
      markers: true,
      series: [
        { name: "max_seen = ⌊opsSeen / 10⌋", color: "var(--series-1)", values: maxSeen },
        { name: "throttle line (opsIncluded + 10)", dash: true, color: "var(--text-muted)", values: snaps.map((p) => (p.opsIncluded === null ? null : p.opsIncluded + 10)) },
      ],
    });
    table($("meas-table"), ["snapshot", "opsSeen", "opsIncluded", "status", "staked"], snaps.map((p) => [p.label, p.opsSeen ?? "–", p.opsIncluded ?? "–", p.status ?? "–", p.isStaked ?? "–"]));
  } else {
    $("meas-chart").innerHTML = `<p class="empty">No measured snapshots yet: run just reputation before / after.</p>`;
  }
}

// -------------------------------------------------------------------------------------------- main

async function refresh() {
  $("refresh").disabled = true;
  try {
    const { config, dep, exo } = await load();
    renderMeta(config, dep);
    const liqs = await liquidationsOf(dep);
    const saved = renderNet(liqs);
    renderTiles(dep, liqs, saved);
    renderCva(dep);
    renderLifecycle(liqs, config);
    await renderPositions(dep);
    renderExo(exo, dep, config);
  } catch (e) {
    $("meta").innerHTML = `<span class="bad">${esc(e.message)}</span>`;
  } finally {
    $("refresh").disabled = false;
  }
}

const themeParam = new URLSearchParams(location.search).get("theme");
if (themeParam === "light" || themeParam === "dark") document.documentElement.dataset.theme = themeParam;
$("refresh").addEventListener("click", refresh);
$("theme").addEventListener("click", () => {
  const cur = document.documentElement.dataset.theme ?? (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
  document.documentElement.dataset.theme = cur === "dark" ? "light" : "dark";
  refresh();
});
$("crash").addEventListener("click", async () => {
  const btn = $("crash"), log = $("crash-log");
  btn.disabled = true;
  log.hidden = false;
  log.textContent = "starting just scene crash …\n";
  try {
    const r = await fetch("/api/crash", { method: "POST" });
    const reader = r.body.getReader();
    const dec = new TextDecoder();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      log.textContent += dec.decode(value);
      log.scrollTop = log.scrollHeight;
    }
  } catch (e) {
    log.textContent += `\n${e.message}`;
  } finally {
    btn.disabled = false;
    refresh();
  }
});
refresh();
