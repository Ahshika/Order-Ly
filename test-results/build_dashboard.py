"""Builds test-results/index.html from the real result files (no network, no external assets).

Usage (from the repo root):  python test-results/build_dashboard.py
Inputs:
  stress/before_fix_results.json, stress/after_fix_results.json   (flutter test test_stress)
  load/*/summary.json                                              (k6 --summary-export)
  security/gitleaks.json, security/semgrep.json, security/trivy.json
"""
import html
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent


def load(rel):
    p = ROOT / rel
    return json.loads(p.read_text(encoding="utf-8")) if p.exists() else None


def esc(v):
    return html.escape(str(v))


before = {r["scenario"]: r for r in (load("stress/before_fix_results.json") or {"results": []})["results"]}
after = (load("stress/after_fix_results.json") or {"results": []})["results"]

rows = []
for r in after:
    b = before.get(r["scenario"], {})
    details = {k: v for k, v in r.items() if k not in ("scenario", "status", "note", "examples")}
    rows.append(
        f"<tr><td>{esc(r['scenario'])}</td><td class='s {esc(b.get('status', '-'))}'>{esc(b.get('status', '-'))}</td>"
        f"<td class='s {esc(r['status'])}'>{esc(r['status'])}</td><td><code>{esc(json.dumps(details, ensure_ascii=False))[:400]}</code>"
        f"{('<div class=note>' + esc(r['note']) + '</div>') if r.get('note') else ''}</td></tr>"
    )
counts = {s: sum(1 for r in after if r["status"] == s) for s in ("PASS", "FAIL", "INFO")}
fixed = sum(1 for r in after if r["status"] == "PASS" and before.get(r["scenario"], {}).get("status") == "FAIL")

load_rows = []
for summary in sorted((ROOT / "load").glob("*/summary.json")):
    m = json.loads(summary.read_text(encoding="utf-8")).get("metrics", {})

    def g(name, key):
        v = m.get(name, {}).get(key)
        return "-" if v is None else (f"{v:.0f}" if isinstance(v, (int, float)) and key != "value" else f"{v}")

    failed_rate = m.get("http_req_failed", {}).get("value")
    load_rows.append(
        f"<tr><td>{esc(summary.parent.name)}</td><td>{g('http_reqs', 'count')}</td><td>{g('http_reqs', 'rate')}/s</td>"
        f"<td>{g('orders_ok', 'count')}</td><td>{g('order_time', 'med')} / {g('order_time', 'p(95)')} / {g('order_time', 'max')} ms</td>"
        f"<td>{g('screen_time', 'p(95)')} ms</td><td>{'-' if failed_rate is None else f'{failed_rate * 100:.3f}%'}</td>"
        f"<td>{g('server_errors', 'count') if 'server_errors' in m else g('orders_failed', 'count')}</td>"
        f"<td><a href='load/{esc(summary.parent.name)}/k6-report.html'>k6 report</a></td></tr>"
    )

# ---- Playwright (customer QR menu)
pw = load("web/playwright.json") or {}
pw_rows, pw_counts = [], {}


def walk(suite):
    for spec in suite.get("specs", []):
        for t in spec.get("tests", []):
            res = (t.get("results") or [{}])[-1]
            st = res.get("status", "?")
            err = (res.get("error") or {}).get("message", "")
            if "spawn UNKNOWN" in err:
                st = "BLOCKED"
            pw_counts[st] = pw_counts.get(st, 0) + 1
            pw_rows.append(f"<tr><td>{esc(spec['title'])}</td><td>{esc(t.get('projectName'))}</td><td class='s {'PASS' if st == 'passed' else 'INFO' if st == 'BLOCKED' else 'FAIL'}'>{esc(st)}</td></tr>")
    for s in suite.get("suites", []):
        walk(s)


for s in pw.get("suites", []):
    walk(s)
contract = load("web/contract_results.json") or []
contract_rows = "".join(
    f"<tr><td>{esc(c['test'])}</td><td>{esc(c['browser'])}</td><td class='s {esc(c['status'])}'>{esc(c['status'])}</td><td>{esc(c['orderStatus'])}</td>"
    f"<td>{esc(c['pageTotalCents'])} / {esc(c['serverTotalCents'])}</td><td>{esc(c['proofKB'])}</td></tr>" for c in contract)

# ---- ZAP
zap = load("security/zap/zap-report.json") or {}
zap_rows = "".join(
    f"<tr><td>{esc(a['riskdesc'])}</td><td>{esc(a['alert'])}</td><td>{esc(a['count'])}</td><td>{esc((a['instances'] or [{}])[0].get('uri', ''))[:80]}</td></tr>"
    for s in zap.get("site", []) for a in s.get("alerts", []))

# ---- Android
android = load("android/android_results.json") or {"results": []}
android_rows = "".join(
    f"<tr><td>{esc(r['scenario'])}</td><td class='s {esc(r['status'])}'>{esc(r['status'])}</td><td>{esc(r['evidence'])}"
    f"{('<div class=note>' + esc(r['note']) + '</div>') if r.get('note') else ''}</td>"
    f"<td>{('<a href=\"android/' + esc(r['screenshot']) + '\">screenshot</a>') if r.get('screenshot') else ''}</td></tr>" for r in android["results"])

# ---- Cost per request (ms) before/after the performance fixes
cost = load("stress/endpoint_cost.json") or {}
cost_labels = list(cost.keys())
cost_rows = "".join(
    "<tr><td>" + esc(ep) + "</td>" + "".join(f"<td>{esc(cost[l].get(ep, '-'))}</td>" for l in cost_labels) + "</tr>"
    for ep in (cost[cost_labels[0]].keys() if cost_labels else []))

# ---- Monitored load (Prometheus)
prom = load("load/ramp-monitored/prometheus-export.json") or {}
prom_rows = "".join(f"<tr><td>{esc(k)}</td><td>{'-' if v.get('max') is None else f'{v['max']:.1f}'}</td><td>{'-' if v.get('avg') is None else f'{v['avg']:.1f}'}</td></tr>" for k, v in prom.items())

leaks = load("security/gitleaks.json") or []
semgrep = load("security/semgrep.json") or {}
trivy = load("security/trivy.json") or {}
trivy_vulns = sum(len(r.get("Vulnerabilities") or []) for r in trivy.get("Results", []))
trivy_secrets = sum(len(r.get("Secrets") or []) for r in trivy.get("Results", []))

page = f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Order Ly Test Results</title>
<style>
:root{{--bg:#fff;--fg:#1b1f24;--mut:#5b6470;--line:#d9dee4;--pass:#1a7f37;--fail:#cf222e;--info:#6e7781;--card:#f6f8fa}}
@media (prefers-color-scheme: dark){{:root{{--bg:#0d1117;--fg:#e6edf3;--mut:#9da7b3;--line:#30363d;--pass:#3fb950;--fail:#f85149;--info:#8b949e;--card:#161b22}}}}
body{{background:var(--bg);color:var(--fg);font:14px/1.5 system-ui,Segoe UI,sans-serif;margin:0;padding:16px;max-width:1200px;margin-inline:auto}}
h1{{margin:.2em 0}} h2{{margin-top:1.6em;border-bottom:1px solid var(--line);padding-bottom:4px}}
.cards{{display:flex;flex-wrap:wrap;gap:12px}} .card{{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:10px 14px;min-width:150px}}
.card b{{font-size:22px;display:block}} table{{border-collapse:collapse;width:100%;font-size:13px}} .wrap{{overflow-x:auto}}
td,th{{border-bottom:1px solid var(--line);padding:6px 8px;text-align:left;vertical-align:top}} code{{font-size:12px;word-break:break-all}}
.s{{font-weight:600}} .PASS{{color:var(--pass)}} .FAIL{{color:var(--fail)}} .INFO{{color:var(--info)}} .note{{color:var(--mut);font-size:12px}} a{{color:inherit}}
</style></head><body>
<h1>Order Ly — worst-case test results</h1>
<p style="color:var(--mut)">Generated from the raw files in this folder. Version 1.0.7 + fixes from this run. All numbers are real outputs; nothing is typed by hand.</p>
<div class="cards">
<div class="card"><b class="PASS">{counts['PASS']}</b>worst-case scenarios pass</div>
<div class="card"><b class="FAIL">{counts['FAIL']}</b>fail (after fixes)</div>
<div class="card"><b>{fixed}</b>were failing before the fixes</div>
<div class="card"><b class="INFO">{counts['INFO']}</b>informational</div>
<div class="card"><b>{len(leaks)}</b>gitleaks hits (see SUMMARY)</div>
<div class="card"><b>{len(semgrep.get('results', []))}</b>semgrep findings</div>
<div class="card"><b>{trivy_vulns}</b>trivy dependency CVEs</div>
</div>
<h2>Functional / security worst cases (flutter test test_stress)</h2>
<div class="wrap"><table><tr><th>Scenario</th><th>Before fix</th><th>After fix</th><th>Measured</th></tr>{''.join(rows)}</table></div>
<h2>Load (k6, local, same laptop runs server + k6)</h2>
<div class="wrap"><table><tr><th>Run</th><th>Requests</th><th>Rate</th><th>Orders ok</th><th>Order time med / p95 / max</th><th>Screens p95</th><th>http_req_failed</th><th>Server errors</th><th></th></tr>{''.join(load_rows) or '<tr><td colspan=9>not run</td></tr>'}</table></div>
<h2>Server cost per request (ms, busy cafe: 310 tables, 150 open checks)</h2>
<p style="color:var(--mut)">before = before the round-3 performance fixes; after / after-n1 = after them. Same laptop; runs vary about ±30%.</p>
<div class="wrap"><table><tr><th>Endpoint</th>{''.join(f'<th>{esc(l)}</th>' for l in cost_labels)}</tr>{cost_rows or '<tr><td>not run</td></tr>'}</table></div>
<h2>Live monitoring (k6 → Prometheus → Grafana, ramp to 10,000 orders/min)</h2>
<div class="wrap"><table><tr><th>Series</th><th>Max</th><th>Average</th></tr>{prom_rows or '<tr><td colspan=3>not run</td></tr>'}</table></div>
<p><img src="load/ramp-monitored/grafana-dashboard.png" alt="Grafana dashboard of the monitored run" style="max-width:100%;border:1px solid var(--line);border-radius:8px"></p>
<h2>Customer QR menu in real browsers (Playwright)</h2>
<p>{', '.join(f'{esc(k)}: {v}' for k, v in sorted(pw_counts.items()))} — <a href="web/report/index.html">Playwright report</a>. BLOCKED = the Firefox build on this PC does not start (environment).</p>
<div class="wrap"><table><tr><th>Test</th><th>Browser</th><th>Result</th></tr>{''.join(pw_rows)}</table></div>
<h3>What the page sent, ingested by the real server</h3>
<div class="wrap"><table><tr><th>Test</th><th>Browser</th><th>Result</th><th>Order</th><th>Page total / server total (piastres)</th><th>Proof KB</th></tr>{contract_rows}</table></div>
<h2>Android app on an emulator (Appium + UiAutomator2)</h2>
<div class="wrap"><table><tr><th>Scenario</th><th>Result</th><th>Evidence</th><th></th></tr>{android_rows}</table></div>
<h2>OWASP ZAP 2.17 active scan (temporary server)</h2>
<p>The "SQL Injection" alert was checked by hand and is a false positive (see SUMMARY.md); X-Powered-By was removed after this scan.</p>
<div class="wrap"><table><tr><th>Risk</th><th>Alert</th><th>Count</th><th>Example</th></tr>{zap_rows}</table></div>
<p><a href="security/zap/zap-report.html">ZAP HTML report</a></p>
<h2>Security scans</h2>
<ul>
<li>gitleaks: {len(leaks)} hit(s) — <a href="security/gitleaks.json">gitleaks.json</a></li>
<li>semgrep (p/default, Community Edition): {len(semgrep.get('results', []))} finding(s), {len(semgrep.get('paths', {}).get('scanned', []))} files scanned — <a href="security/semgrep.json">semgrep.json</a></li>
<li>trivy fs: {trivy_vulns} vulnerabilities, {trivy_secrets} secrets — <a href="security/trivy.json">trivy.json</a></li>
</ul>
<h2>Raw files</h2>
<ul><li><a href="SUMMARY.md">SUMMARY.md</a></li><li><a href="baseline/flutter_test.txt">baseline flutter test</a></li>
<li><a href="stress/before_fix_run.txt">stress run before fixes</a> / <a href="stress/after_fix_run.txt">after fixes</a></li>
<li><a href="regression_after_fix.txt">regression run after fixes</a></li></ul>
</body></html>"""
(ROOT / "index.html").write_text(page, encoding="utf-8")
print("wrote", ROOT / "index.html")
