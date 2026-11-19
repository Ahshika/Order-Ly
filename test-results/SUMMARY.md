# Order Ly — worst-case test report

| | |
|---|---|
| Project | Order Ly (cafe POS + QR ordering) |
| Version tested | 1.0.7+8 (branch `claude/comprehensive-stress-testing-f1539b`), before and after the fixes below |
| Date | 2026-11-19 |
| Machine | Windows 11 Pro, i7-13650HX (20 threads), 16 GB RAM (~1.6 GB free during the run) — server and load generator on the same laptop |
| Data | Every test runs on a temporary folder. No real cafe data and no live Firebase project were touched. |

## Tools (all free, local)

| Tool | Version | Edition / cost | Used for |
|---|---|---|---|
| Flutter / Dart | 3.47.5 / 3.13.4 | open source, free | unit, integration, worst-case suite |
| Grafana k6 | local `k6.exe` (OSS) | open source, free, no cloud | ramp + spike load |
| gitleaks | 8.30.1 | open source, free | secrets in repo + history |
| Semgrep | Community Edition, `p/default`, `--metrics=off` | free | static analysis (HTML/JS; Dart rule coverage is limited) |
| Trivy | 0.76.2 | open source, free | dependency CVEs, secrets, misconfig in `source/` |
| Python | 3.13.15 | free | report/dashboard generation, Appium client (stdlib only) |
| Playwright `@playwright/test` | 1.64.0 (installed project-locally in `source/test_web`, with approval) | Apache-2.0, free | customer QR menu on Chromium (Pixel 7) and WebKit (iPhone 14); Firefox build on this PC is broken → BLOCKED |
| OWASP ZAP | 2.17.0 (Temurin 17) | Apache-2.0, free | active scan of a temporary server |
| Prometheus | 3.16.0 | Apache-2.0, free | live metrics (k6 remote write + server exporter), temporary instance on :19090 |
| Grafana OSS | 13.3.0 | AGPL, free | live dashboard, separate temporary instance on :13000 (your Grafana service on :3000 untouched) |
| Appium + UiAutomator2 | 4.0.0 / 9.2.2 | Apache-2.0, free | Android app UI on the emulator (AVD `fiberlens_phone`, run read-only) |
| Android SDK emulator | API 34 x86_64 | free | device |

## Commands

```
cd source
flutter test                                   # baseline + regression (50 tests)
flutter test test_stress --timeout 300s        # worst-case suite
powershell -ExecutionPolicy Bypass -File test_load\run.ps1 -K6 <k6.exe> -Out <abs-or-rel dir>                    # 5-min ramp
powershell -ExecutionPolicy Bypass -File test_load\run.ps1 -K6 <k6.exe> -Script spike.js -Out <dir>               # spike + junk
gitleaks detect --source . --redact
semgrep scan --config p/default --metrics=off source/lib source/firebase source/test_load
trivy fs --scanners vuln,secret,misconfig source
python test-results/build_dashboard.py         # builds test-results/index.html
```

## Results at a glance

| Suite | Result |
|---|---|
| Existing tests (`flutter test`) before changes | 50 / 50 PASS |
| Worst-case suite on the **original** code | 17 PASS, **13 FAIL** (11 in the first run + 2 race tests added later and run on an untouched copy of `HEAD`) |
| Worst-case suite after the fixes | **30 / 30 PASS** (1 extra INFO entry: corrupt-DB start-up, see "Still open") |
| Existing tests after the fixes (regression) | 50 / 50 PASS |
| `dart analyze` | 0 errors, 0 warnings (3 old style hints, not from this change) |

**Load (k6, local).** Server and k6 ran on the same laptop, so these are lower bounds.

| Run | Requests | Orders | Order time median / p95 / p99 / max | Screens p95 | Failed | Server event-loop lag avg / max |
|---|---|---|---|---|---|---|
| Ramp 500 → 10,000 orders/min, 5 min (`orders.js`) | 58,865 | 25,804 | 3 / **96** / 1,087 / 1,339 ms | 33 ms | **0** (0.000%) | 13.7 / 639 ms |
| *For reference: 1.0.6 in the repo* | | 26,027 | p95 236 ms | 97 ms | 0 | |
| Spike 0→400→600 devices + 10% junk (`spike.js`, 2 min) | 40,574 | — | 844 / 1,473 / 1,894 / 2,098 ms | **3,503 ms** | 16 (0.04%), see below | 398 / 1,290 ms |

- All thresholds of the ramp test passed. The order-time p95 is better than the 1.0.6 numbers in the repo, but it was measured on a different run of the same machine, so treat it as "no regression", not as a speed-up.
- **Spike:** no real route returned a 5xx. All **16 "failed" requests** were deliberate junk: 4 MB login bodies. The server refuses these without reading them (HTTP 413 or the 5-tries login lock). It does not close the socket, so k6's upload stalls until k6's own 30 s timeout. The server stays fine.
- **Spike, real limit:** with 600 devices hammering at once (about double a large cafe, with no pauses), the server's single thread saturates. Screens take a p95 of 3.5 s (threshold 1.5 s: **FAIL**), and the event loop lags by about 0.4 s on average. Nothing failed or got corrupted; it only got slow. 2,491 4xx answers were the expected "check already closed by another device" conflicts. 1,625 junk requests were rejected cleanly.

## Bugs found and fixed

| # | Severity | What happens (worst case) | Fix | Evidence |
|---|---|---|---|---|
| 1 | HIGH | **Check changed after it was paid and closed.** A phone on weak Wi-Fi is still uploading a request when the cashier closes the check. The server had already loaded the check as "open", so when the upload finished it applied the change anyway: discount on a paid check (report shows 50 EGP, drawer has 100), item voided on a paid check (total 0, paid 100), **split moved paid items into a new open check (customer billed twice)**, merge turned a paid check into "void". | Every handler that acts on an existing check/payment/shift now reads the request body first and only then loads the record. (`routes_checks.dart`, `routes_payments.dart`, `routes_inventory.dart`, `api_server.dart`) | `race.*` before: FAIL ×4 → after: PASS |
| 2 | HIGH | Same pattern on transfers and the drawer: two cashiers pressing "confirm" on the same InstaPay/wallet transfer could both succeed → the drawer counts it twice; two devices could open two shifts at once. | Same fix. | `race.double_confirm_transfer`, `race.double_register_open` PASS after the fix and FAIL on the unmodified code (run in a separate checkout of `HEAD`, see below). |
| 3 | HIGH | **Anyone on the cafe Wi-Fi, without logging in**, could send a huge body to `/api/auth/login`; the server buffered all of it in memory (+161 MB for a 64 MB body). A few parallel requests can take the cashier PC down. | Body capped at 12 MB (largest real request is an 8 MB menu photo); `Content-Length` checked first, then counted while streaming → HTTP 413. | `dos.huge_unauth_body`: 400 / +161 MB → 413 / +19 MB |
| 4 | HIGH | **Image bomb from the internet.** Transfer screenshots come from customers through Firebase (anyone with a table QR). A 117 KB PNG of 10000×10000 px made the server decode 100 megapixels (1.7 s, ~100+ MB); the Firebase limit (1.2 MB) allows far bigger ones → out of memory. | Image size read from the header before decoding; anything over 50 MP is refused (`maxDecodePixels`). Same guard on the logo. | `dos.image_bomb`: decoded in 1699 ms → refused in 7 ms |
| 5 | MEDIUM | **Stock grew out of nothing.** Voiding an item of a QR order that was never accepted (or voiding the whole check) "returned" ingredients that had never been taken (1000 g → 1050 g). | `_returnStock` skips lines of orders still `pending` (stock is only taken on accept). | `inventory.void_pending_qr_order`: 1050 → 1000 |
| 6 | MEDIUM | Confirming a transfer accepted **any** amount (49,950 EGP on a 50 EGP check), and a pending transfer could be confirmed on a voided check → inflated drawer and reports. | Confirm is limited to what is left on the check (+ orders still waiting for approval, since customers may pay before the cashier accepts). Closed/void check → refused. | `money.confirm_overpayment` FAIL → PASS |
| 7 | MEDIUM | **A broken backup could be staged for restore.** After the restart the server could not open the database and the cafe would be down until someone fixed it by hand. | Restore now extracts the database to a scratch file and runs `PRAGMA quick_check` + checks it is an Order Ly database before staging. | `restore.garbage_db`: 200 → 400 |
| 8 | LOW | 191 of 564 fuzzed requests (wrong JSON types: number instead of text, list instead of id…) crashed the handler with HTTP 500 and filled the error log. | Typed field reader `_field<T>()` → 400 "البيانات المبعوتة مش مفهومة"; id/area/station checks verify the type before hitting SQLite. | `fuzz.wrong_types`: 191 → 0 server errors |
| 9 | LOW | A phone disconnecting mid-upload was logged as a server ERROR with a stack trace (1000 entries in the slowloris test). | Treated as 400, not logged as a crash. | server log noise gone |
| 10 | LOW | A QR order whose name/note/payment fields had the wrong type was silently dropped (customer never sees a reason). | Customer message fields parsed leniently (`_text`), so the order is processed or rejected with a reason. | `fuzz.qr_messages` |
| 11 | LOW (tooling) | `test_load/run.ps1` did not run under Windows PowerShell 5.1. Three causes: the file was UTF-8 without a BOM and contains Arabic text; a relative `-Out` path broke; and the first k6 warning on stderr became a fatal error that killed k6 mid-test. Also added `-Script` to choose a scenario. | Added the BOM, made the output path absolute, and stopped treating k6's stderr as fatal. | load runs above |

## Worst cases that already held (no change needed)

300 simultaneous orders on one check (totals exact, order numbers unique) · 50 devices opening the same table (one check) · 20 cashiers paying the full amount at once (paid once) · close vs void at the same moment · 400 live screens on WebSocket during 100 orders · 1000 half-open "slowloris" connections (normal requests still answered in a few ms) · 60 lines × 99 × maximum prices with 50% service + 50% tax (no overflow) · negative/absurd/1e400 numbers · 134 role/permission checks (anonymous, fake token, every role, disabled user, token in URL) · SQL injection strings in every search box and id · 500 random malformed QR messages (no half-written orders, DB integrity ok) · replayed QR message ids (stored once) · login brute force (locked after 5) · zip-slip paths in a backup (nothing written outside the data folder) · server stopped while 200 requests were in flight (no half orders, integrity ok).

## Still open after round 1 (all of these were fixed in round 3, see below)

| Severity | Issue | Why not fixed here |
|---|---|---|
| MEDIUM | **QR order flood.** The "8 orders per phone per 10 minutes" limit is keyed on an id the customer's browser chooses; rotating it let 200 pending orders in (`qr.flood`). Someone sitting at a table can fill the cashier's inbox. | Needs a server-side limit in Firebase (rules per table key / App Check) or a per-table limit in the app — a product decision. |
| MEDIUM | **Saturation at ~600 simultaneous busy devices**: screens p95 3.5 s, event loop lag up to 1.3 s (spike run). Fine at realistic cafe load (ramp run). | Would need moving heavy reads off the main isolate / caching the floor & KDS JSON — a performance project, measured but not changed here. |
| LOW | Refused oversized/locked-out requests are answered without draining or closing the connection, so the sender hangs until its own timeout. Harmless for the server. | Could add `connection: close` on early error responses; not needed for safety. |
| MEDIUM | **Corrupted database at start-up** (power cut during a write, bad disk): the server refuses to start (`SqliteException(11)`), the host retries 60 times, and recovery is manual. | Automatic fallback to the latest backup is a feature, not a bug fix. |
| LOW | Device-limit check is skipped when the client omits `deviceName` (licence bypass, not a data risk). | Licensing design. |
| LOW | Token is accepted in the URL (`?token=`) on every route, not only the WebSocket; URLs end up in logs. LAN only. | Changing it touches every client. |
| LOW | Any logged-in role (including kitchen) can download transfer screenshots via `/api/files/<id>` and report any print job as done. | Needs a role decision. |
| INFO | gitleaks flags the Firebase **web** API key in `firebase_config.dart`. This key is public by design (it is also in the customer menu page); access is controlled by `database.rules.json`. Not a secret; no rotation needed. | — |

## Round 2 — extra tools (Playwright, ZAP, Prometheus + Grafana, Android + Appium)

| Area | Result |
|---|---|
| **Customer QR menu, real browsers** (`test_web`, 14 scenarios × 3 browsers, Firebase fully mocked) | Chromium-Android **14/14**, WebKit-iPhone **14/14** after 2 fixes. Firefox **BLOCKED**: the Playwright Firefox build installed on this PC fails to start ("side-by-side configuration is incorrect"); this is the environment, not the app. |
| **Menu → real server contract** | The 6 orders the browsers really sent (normal, takeaway, wallet + transfer screenshot) were fed into the real server: all were stored as pending orders, the page total matched the server total, and the screenshot was stored. A 4000×3000 noise photo (worst case to compress) was shrunk on the phone to 285–460 KB, under the 1.2 MB Firebase limit. |
| **OWASP ZAP active scan** | 1 High "SQL Injection" on `/checks/<id>/customer` → **false positive**, verified: parameterised SQL. The answer changed only because the first customer name written to a check is kept. A test now proves the payload is stored literally. 2 Low: "XSS weakness in JSON" (low confidence; the app renders text and the menu page escapes it, which is accepted) and **X-Powered-By header → fixed**. No server errors during the scan. |
| **Live monitoring** (`run_monitored.ps1`) | Ramp to 10,000 orders/min: 26,061 orders, **0.000 %** failed. Up to 166 orders/s. Order p95 max 26 ms (5 s windows). Server event-loop lag avg 5.5 ms, spikes up to ~200 ms only in the final 9,500–10,000/min stages. Memory peaks at ~200 MB, DB reaches 88 MB. Grafana screenshot is in `load/ramp-monitored/grafana-dashboard.png`. |
| **Android app on the emulator** (Appium) | 9/9 scenarios PASS: connect + login; ordering with required size/extras (125 EGP on the phone = 12500 on the server); live update from another device in 3 s; Wi-Fi cut at send (the draft is kept, the error is shown, no duplicate after reconnecting); check closed on another device (red banner, send disabled); rotation + 6 s in the background; GPRS network (7 KB/s): open a table and send in 4.7 s. Details: `android/android_results.json`. |

**New fixes from round 2**

| # | Severity | Issue | Fix |
|---|---|---|---|
| 12 | MEDIUM | **XSS on the customer's phone:** the reason staff type when rejecting a payment (`p.r`) was put into the menu page's HTML without escaping. Anyone who can reject a transfer could run script in the customer's browser. | `esc()` in `firebase/public/menu.html`. **Needs `firebase deploy` to reach customers.** |
| 13 | LOW | The menu page crashed (blank page) if the phone had an unknown saved language. | Falls back to Arabic. Same deploy note. |
| 14 | LOW | Server sent `X-Powered-By: Dart with package:shelf`; JSON responses lacked `nosniff`. | Header removed; `X-Content-Type-Options: nosniff` added. |
| 15 | LOW | The first screen of the app said "نظام إدارة محلات صيانة الموبايلات" (a phone-repair shop system), copied from another project. | Now "نظام كاشير وطلب بالـ QR للكافيهات". |
| 16 | LOW (tooling) | Three more Windows PowerShell 5.1 problems in the new scripts: `$PSScriptRoot` is empty in `Mandatory` params; Start-Process doesn't quote paths with spaces; Grafana won't create its own data folder. | Handled in `zap_scan.ps1` / `run_monitored.ps1`. |

**UX notes from the device (not bugs, not changed):** the "can't reach the server" message disappears after ~4 s and there is no lasting offline indicator. After another device closes the check, the unsent item stays on screen with no button to move it to a new check.

**Open risk found by reasoning, not reproduced:** if the server saves a staff order but the reply is lost (Wi-Fi drops on the way back), the app shows "can't reach the server" and the waiter may send it again. Staff orders have no idempotency key, so this would create a duplicate kitchen ticket. Reproducing it needs a fault-injecting proxy.

## Round 3: closing everything that was left open

The product is not in use yet (hardening before sale), so the open items were fixed instead of left as risks.

| # | What | Before | Now | Evidence |
|---|---|---|---|---|
| 17 | **Backup schedule (new feature)** | Fixed: once a day, keep 14, nothing the owner can change. Changing any backup setting also **wiped the second backup folder** (a bug). | The owner picks: every 1/3/6/12/24 hours or weekly; keep 7/14/30/60; optional backup after every shift close. Checked every 10 minutes. Two backups can't run on top of each other. A failed backup shows its reason on the screen. The second folder changes only when it is actually edited. The screen shows the expected disk use. | `test/hardening_test.dart` › backup schedule (4 tests) |
| 18 | **Corrupted database at start-up** | The server refused to start; manual recovery only. | The broken file goes into `corrupt-<date>/` (kept, never deleted). The server takes the newest **valid** backup (from the backups folder, then the second folder) and starts. The owner sees a red notice on the home screen and in Backups: which backup was used, and that anything after it must be re-checked. If no valid backup exists: a clear error, and the broken file is still kept. A file with a small problem that is still readable is **not** replaced (that would lose hours of work); it is used, with a warning. | 2 tests: restore from the newest good backup while skipping a broken newer one; no backup at all |
| 19 | **Transfer screenshots** | Any logged-in user (kitchen, waiter) could open them. | Owner, supervisor and cashier only. Waiters see "صورة التحويل للكاشير بس". Menu photos are still visible to everyone. | waiter/kitchen 403, cashier 200 |
| 20 | **Token in the URL** | Accepted on every route (URLs end up in logs and screenshots). | Only on the live connection (`/api/ws`); anywhere else it gets 401. | worst-case authz matrix + hardening test |
| 21 | **Device limit bypass** | The limit was skipped when the device name was missing, and Android phones are all named "Android - localhost", so **all phones counted as 1 device**. | Devices are counted by the unique id each install already had. Login without it gets 400 ("حدّث البرنامج"). | 3 devices with the same name: the 3rd beyond the trial is refused (402) |
| 22 | **Print results** | Any user could mark any ticket as printed, so it would never print. | Only the device that took the job (by its session's device id) or a manager. | waiter 403, the printer itself 200 |
| 23 | **Duplicate kitchen tickets** (reply lost, waiter sends again) | Saved twice, printed twice. | Every send carries a request id, and a resend returns the already-saved order (unique index, migration v8). A draft keeps its id until its items change. | the same order sent 11 times (10 at once): 1 order, 1 ticket |
| 24 | **QR flood** | 200 pending orders from one table by rotating phone ids. | Limit per table: 6 waiting, 15 per 10 minutes (takeaway 25 / 60), even on tables that accept automatically. | 30 attempts: exactly 6 waiting; another table unaffected; auto-accept: 15 |
| 25 | **No lasting offline indicator** | A 4 s message, then nothing. | A red bar on top of every screen (including the check screen) while the live connection is down. A 5 s ping detects a silent Wi-Fi drop. Screen readers announce it. | Android: shown 2 s after the cut, still there while offline, gone 12 s after the Wi-Fi came back |
| 26 | **Unsent items stuck after the check was closed elsewhere** | No way to send them. | Button "ابعتها على حساب جديد": opens a new check for the same table and sends them. | Android: new check on table 1 with exactly 65 EGP |
| 27 | **Server stop crashed when phones were connected** (found by the new tests: intermittent, 1 run in 5) | `ConcurrentModificationError` in `stop()`, so the database was not closed cleanly. | It loops over a copy of the connection list. | 8/8 repeated runs pass |
| 28 | **Performance** | Every request also wrote to the database (last seen; licence clock on every sale). The 4 screens every device polls were rebuilt for each request. Each order added re-read every item order by order (N+1). | Last seen is written at most once a minute, the licence clock once a minute. The screens are cached until anything changes (max 2 s). Items are loaded in one query. | Cost per request (small cafe): kitchen screen **8.2 → 2.1–2.5 ms**, floor **4.1 → 1.3–1.5**, open checks **3.6 → 1.5**. Spike (600 devices): throughput +9%, order p99 **3.5 → 1.7 s**, screens p99 **6.6 → 3.9 s** |

**Re-tested after round 3 (final code):**
- `flutter test`: **63/63**.
- Worst-case suite: **30/30**.
- Playwright: Chromium + WebKit **28/28**; contract **6/6**.
- Android emulator: **7/7**.
- ZAP: the only finding left is the false-positive "SQL Injection" (proven by a test) plus low/informational notes.
- k6: 0 failed orders in every run.
- Analyzer: 0 errors, 0 warnings.

**Performance: the honest picture**
- At realistic load (the ramp to 10,000 orders/min) there are **0 failures** in every run.
- Where the slowdown starts varied between runs of the same code: about 7,000/min in two plain runs, and full speed to 10,000/min in the monitored run (p95 ≤ 344 ms). An A/B in one process could not pin it on the new indexes; repeated measurements on this laptop move about ±30% after hours of back-to-back load tests. Treat ~7,000 orders/min (≈ 115 orders per second, far beyond any single cafe) as the safe number for this machine.
- The **600-device spike** is still slow (screens p95 ≈ 3.4 s), but nothing fails. It is a ceiling: those 600 devices send requests with no pause, so the wait ≈ devices ÷ throughput. Going beyond it needs a second server thread (read-only database connections in a separate isolate). That is an architecture change, recommended only if a customer really needs hundreds of devices.

## Round 4: notifications, the side notice, Firefox, Firebase

| What | Result |
|---|---|
| **Notifications on phones and PC (new feature)** | The server sends a notification event at each important moment, to the right roles only: QR order (floor staff), table call / bill / "will pay cash" (floor), transfer waiting (cashiers), order sent to prepare (kitchen), order ready (waiters and cashiers), print failed (cashiers). **App open:** side notice + its own sound. **App in the background:** a real notification (Android tray / Windows) with the same sound, and tapping it opens the right screen. **Android with the screen locked:** a foreground service keeps the connection alive (fixed notification "Order Ly شغال"). **Wi-Fi blip:** the server keeps the last 3 minutes and a reconnecting phone gets what it missed, once. Each device has its own settings (on/off, sound, per type, background) with a "try" button per type. |
| **Sounds** | 6 different tones generated by `tool/make_sounds.dart`: pure synthesized tones, so no copyright and no cost. Before this, phones had **no sound at all** (`SystemSound.alert` works on Windows only). |
| **Side notice instead of the bottom bar** | It slides in from the right, max 340 px wide, and hides by itself (3.2 s; errors 5 s; alerts 6 s; with a button 7 s). It closes with a tap or a swipe. At most 3 at once, stacked, and the same text isn't repeated. Found and fixed along the way: notices from a screen that had closed stayed in the list. |
| **Firefox** | The Playwright Firefox build refuses to start from `AppData\Local` on this Windows Insider build (SideBySide: mozglue); the exact same files run from `Temp`. `test_web/run.ps1` detects this and copies it automatically. **Browsers 42/42** (Chromium-Android, WebKit-iPhone, Firefox), contract 9/9. |
| **Firebase** | `firebase deploy --only hosting` to `orderly-yvzug` (logged in as you). The live page now has the XSS fix and the language-crash fix (checked on the live URL). Database rules were not touched. |

**New packages (with your approval):**
- `flutter_local_notifications ^22.3.3` (BSD-3). Version 23 was a week old and needs Android SDK 37 plus a newer Android Gradle plugin than this project's 9.1, so the previous stable version was used.
- `audioplayers ^6.8.1` (MIT).
- `flutter_foreground_task ^11.0.3` (MIT).

Cost: none. No Firebase Cloud Messaging: it would need the paid Blaze plan, or an admin key inside every installer.

**Tested:**
- `flutter test`: **73/73** (+6 notification server tests including the reconnect replay, +4 side-notice widget tests).
- Worst-case suite: **30/30**.
- Browsers: **42/42**.
- Android emulator: **11/11 on the debug APK and 11/11 on the release APK**. Covered: side notice, red "print failed" notice, tray notification on the `orderly_order_ready` channel with our sound, tap opens Orders, background service running.
- Windows and release APK builds succeed. The sound files are inside the release APK.

**Not tested:** Windows desktop notifications on screen (the build compiles, but running the Windows app on this PC would use the real Order Ly data folder and port 8753); how loud it sounds in a real cafe; real phones; Android 15's limits on background services (only Android 14 was emulated).

**Notes for building:**
- This work folder is so deep (`.claude\worktrees\…`) that the Windows build exceeds the 260-character path limit. It builds through a temporary `subst` drive; your normal project folder doesn't have this problem.
- After a build through `subst`, delete `.dart_tool\flutter_build` and `.dart_tool\hooks_runner` (generated caches).

## Not tested

Firefox (fixed in round 4 — now 42/42), real phones/tablets and Windows UI under stress (only the Android emulator was driven), real thermal printers, the live Firebase project (`test_cloud` writes to the real service, so it was not run), real power loss and full disk (only simulated by stopping the server / corrupting the file), date roll-over at midnight, other machines on a real Wi-Fi network. Semgrep's Dart coverage is limited; the customer menu page uses `esc()` consistently for `innerHTML` but was not exhaustively reviewed for XSS. Scanners cannot prove the absence of vulnerabilities.

## Cost

Paid tools: NONE · Paid subscriptions: NONE · Paid APIs: NONE · Paid cloud services: NONE · Paid licences: NONE · Paid infrastructure: NONE.

## Files

- `index.html` — local dashboard (open in any browser, works offline)
- `baseline/flutter_test.txt` — existing suite before changes (50/50)
- `stress/before_fix_run.txt`, `stress/before_fix_results.json` — worst-case suite on the original code
- `stress/after_fix_run.txt`, `stress/after_fix_results.json` — same suite after the fixes
- `regression_after_fix.txt` — existing suite after the fixes
- `load/ramp-1.0.7-fixed/`, `load/spike-1.0.7-fixed/` — k6 reports, summaries, server metrics
- `security/` — gitleaks (redacted), semgrep, trivy JSON; `security/zap/` — ZAP plan, HTML/JSON report
- `web/` — Playwright HTML report (`report/`), `playwright.json`, captured messages, `contract_results.json`
- `load/ramp-monitored/` — k6 + Prometheus export + Grafana screenshot and importable dashboard
- `android/` — `android_results.json`, screenshots of each worst case, Appium/emulator logs
