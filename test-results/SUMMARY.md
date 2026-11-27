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

## Round 5: branches (2026-11-21, branch `claude/multi-branch`)

**New feature.** Several cafes (each its own server PC and database) under one owner. The main branch creates a link code. Another branch types the code, which sends a join request, and the main branch approves or rejects it. Each linked branch sends a short summary to Firebase at most once a minute, and only when it changed (plus a heartbeat every 5 minutes): sales for today, yesterday, this month and the last 7 days; open checks; busy tables; the register; QR orders and transfers waiting; voids; low stock; devices online; top items; subscription state. Only the main branch can read the summaries. The owner sees them under "الفروع" in the side menu. Nothing else moves between branches: menu, checks and staff stay per branch.

| What | Result |
|---|---|
| Local tests (`test/branches_test.dart`, no internet) | **6/6**: code format, owner-only access (supervisor, cashier, waiter and kitchen get 403, no token gets 401), bad input → 400 before anything goes online, saved states, trial = 2 branches, and the summary numbers against real checks and payments. Names are clipped so the summary stays under the 20,000-character rule. |
| Live Firebase (`test_cloud/branches_cloud_test.dart`) | **1/1**, against the deployed rules, with two temporary cafes and an outside account. Checked: link, approve, summary arrives with the right sales, remove, re-link, and the main branch deleting the link (the branch notices by itself). Refused by the rules: an outsider reading the chain, approving itself, writing a summary, taking over the owner field, replacing or deleting another branch's request, a fake time, too-long or extra fields, a bad code format, or a chain that doesn't exist. A linked branch can't read the chain, can't change its own approval, can't write an oversized summary or another branch's summary, and can't write after it was removed. Every temporary account and record is deleted afterwards. |
| Subscription limit | The main branch's `branches` count limits approvals, counting itself (402 above the limit). The trial now allows 2 (you chose this). |
| Regression | `flutter test` **79/79**; worst-case **32/32**; the old live Firebase test **1/1**; screenshots **13/13** (4 new branch screens). Analyzer: only the 4 old info notes. |
| Found and fixed along the way | `realtime.dart`: after logout, the closed connection still scheduled a reconnect timer. It was harmless (`connect()` returns at once), but it left a timer behind. It's now skipped once the connection is closed. |
| Firebase | `firebase deploy --only database` (you approved it). Hosting and the customer menu were not touched. |
| Secrets | gitleaks: only the public Firebase web key (it ships inside the app by design) and copies of it in build caches. |

Evidence: `branches/local.txt`, `branches/firebase_live.txt`; screenshots in `source/test_visual/shots/branches_*.png`.

**Not tested:** two real PCs in two places (the live test runs both servers on this laptop against the real Firebase); a branch with a wrong clock (the "online" check uses Firebase server time, but the "today" sales use the branch PC's clock); many branches at once (the rules have no count limit, and the main branch enforces the subscription number when it approves).

## Round 6: less Firebase usage (phase 1, 2026-11-23, not committed)

**What changed:**

- **Logo in its own node.** It moved out of `cafes/{uid}/pub` into `cafes/{uid}/logo`. `pub` now carries only its version (`lv`). The menu page downloads the logo once and keeps it on the phone.
- **Silent writes.** Every cashier write uses `print=silent`, so Firebase replies with an empty 204 instead of sending the data back.
- **Connection kept open.** The cashier's HTTPS connection stays open for 2 minutes, so it no longer pays a new TLS handshake on every sync.
- **Smaller item photos.** They are now 240 px instead of 360 px. If an older version had uploaded them bigger, they are uploaded again once.
- **Old tracking deleted.** A customer whose last order is more than 3 hours old gets their tracking (`trackc`) deleted. Before, it stayed forever.
- **One live connection per phone.** Tracking v2 carries the table bill (`tb`), so a phone listens on a single stream. `trackt` is still written, for phones that have not ordered yet and for older pages.
- **Connections close when hidden.** The menu page closes its live connections when the screen is locked or hidden, and reopens them when the customer comes back.
- **Smaller transfer screenshots.** Max 1000 px and about 300 KB, instead of 1280 px and 700 KB.
- **Rules.** `cafes/$uid/logo` is now public read.

**How it was measured:** a new fake Firebase (`source/test/support/fake_firebase.dart`) counts every byte sent back to the caller. That is what Firebase bills as download.

| Measured (`test/cloud_usage_test.dart`: 12 item photos, a logo, 20 QR orders) | Before | After |
|---|---|---|
| `pub` (read every minute by every open menu page) | 62,253 B (logo inside) | **355 B** |
| Data Firebase sent back to the cashier for 20 orders | 78,463 B | **4 B** |
| Data sent back during the first menu upload | 139,809 B | **8 B** |
| Average item photo | 7,139 B | 4,888 B (this test's photos are simple; real photos are bigger and shrink by about the same ratio) |
| New customer, 10 minutes on screen, 30 photos | 903,024 B | **216,751 B** |
| Returning customer (photos and menu already on the phone) | 686,803 B | **6,150 B** |

**Results:**

| Test | Result |
|---|---|
| `flutter test test/` | **85/85** (79 old + 6 new), exit 0 |
| New `test/cloud_sync_test.dart` | **5/5**: every write is silent and nothing comes back; the logo node and `lv` (and both are removed when the logo is deleted); photos at 240 px and re-sent after an upgrade; tracking v2 has the table bill, and tracking older than 3 h is deleted while active customers stay; takeaway has no table bill |
| New `test/cloud_usage_test.dart` | 1/1 (writes the numbers above) |
| Analyzer | only the 3 old info notes |
| Playwright menu tests (14 old + 7 new, × Chromium/Pixel 7, WebKit/iPhone 14, Firefox) | **63/63**, 0 flaky, and the real-server contract test passed too. First run was BLOCKED (`node_modules` missing); restored with `npm ci` (you approved; `@playwright/test` 1.64.0 from the lockfile, no browser download). Before that `npx` had pulled a `playwright` package into the npm cache by itself; it was not used. |
| Measured in the browser | 10 minutes on screen: `pub` downloaded 12 times = **5,964 B** in total, logo **once** (60,013 B), nothing again after a reload. A transfer screenshot (1170×2532 receipt) uploads at **110–126 KB**. A 46 MB random-noise photo (worst case) uploads at 164–263 KB (before: up to 700 KB). While the screen is off: **0 requests** for 7 seconds, and the live connection and `pub` come back when the customer returns. |
| `test_cloud/` (real Firebase) | NOT RUN: it writes to the real project |
| Deploy | NOT DONE: the rules and `menu.html` are not deployed yet |

**Order of release:** the new `menu.html` and rules must be deployed **before** any cashier PC gets the new app. The new page still reads the logo from `pub` (older cashiers) and still listens on `trackt` when tracking has no `v: 2`. An old page with a new cashier would show no logo.

Evidence: `phase1/flutter-test.log`, `phase1/web-run.log`, `firebase-usage/before.json`, `firebase-usage/after.json`.

## Round 7: phase 2 and the move to a new Firebase project (2026-11-23)

| What | Result |
|---|---|
| Old project `orderly-yvzug` (account 667) | All test data deleted from the database (backup kept locally first). The 9 test sign-in accounts are still there: the CLI cannot delete them. The new rules and page from round 6 are deployed and checked. |
| Phase 2 (a Firebase project per shop, settings inside the signed license) | Committed `b7c4bfb`. `flutter test` **89/89**, Playwright **66/66** |
| New main project `orderly-cafe-28129` (account ahmedhassanshika655, Spark, no card) | Realtime Database in europe-west1, web app registered, rules and menu page deployed. Checked from outside: `pub`, `menu`, `logo` and `trackt` 200; `inbox`, `cafes` and `chains` 401; the live page points at the new database. |
| Code moved to the new project | `firebase_config.dart`, `menu.html`, `.firebaserc` (+ `firebase login:use` 655 for that folder), and the test constants. `flutter test` **89/89**, Playwright **66/66** on 3 browsers, contract test OK |
| Existing installs | An install that was on the old project can't sign in on the new one, so it makes a new account by itself (phase 2) and re-sends everything. |
| Email/Password on the new project | Enabled by you. A probe account was created and deleted at once. |
| Live end-to-end on the new project (`test_cloud/cloud_test.dart`, `test_cloud/branches_cloud_test.dart`) | **2/2**, against the deployed rules: phone → Firebase → cashier, status back to the phone, and the branch link with every rule refusal. Afterwards the database is empty (`null`) and **0** sign-in accounts are left. |
| Still open | An empty Google Cloud project `orderly-cafes` (no Firebase, no billing) is left from the first try. The old project `orderly-yvzug` (account 667) is untouched, with its 9 empty test sign-in accounts. |

Evidence: `move/flutter-test.log`, `move/web-run.log`, `move/cloud-live.log`, `web-move/`, `phase2/flutter-test.log`.

## Round 8: phase 3, the business day and a report for every shift and day (2026-11-23)

**What changed:**

- **Working hours** (`dayOpen`, `dayClose`) are set in "بيانات الكافيه". "24 ساعة" means one end-of-day time. The day ends at a single cutoff in the middle of the hours the cafe is closed (`lib/src/core/business_day.dart`). The default 00:00–00:00 keeps the old midnight day.
- **Everything uses the business day:**
  - order numbers (`_today`)
  - the reports screen (a date without a time = the start of that business day)
  - the cashier's "today"
  - the branch summary (`bd` + the day labels)
- **New endpoints** (owner only):
  - `/api/reports/day?date=`: sales, payment methods, check types, sources, hours, expenses by category, voids (who and why), discounts, top 20 items, feedback, the shifts with counted vs expected cash, open checks and low stock.
  - `/api/reports/shift/<id>`: one shift.
- **Reports go to Firebase** under `rep/{cafe}/{day}/day` and `.../shifts/{id}`:
  - today's report on every register change;
  - yesterday's whenever it changes (this is the final report once the day ends, plus any later correction);
  - days missed while the PC was off (up to 31).
- **Rules:** `rep/$uid` is readable and writable only by the cafe itself, with day-key and size validation. Owner access from outside comes in phase 5.
- **Robustness:**
  - Reports go in their own write, so a refused report never blocks the menu or order tracking.
  - **Bug fixed (it predates this phase):** a write that failed (internet dropping for a moment) left the data marked as sent, so a customer's order status could stay stale until it changed again. Now it is sent again on the next normal cycle.

| Test | Result |
|---|---|
| `flutter test test/` | **103/103**. New: `business_day_test` (7), `day_reports_test` (5), plus 2 in `cloud_sync_test`: refused reports don't stop the menu; a failed write is re-sent (checked to **fail without the fix**) |
| Worst-case suite `test_stress` | **32/32** |
| Live Firebase on `orderly-cafe-28129` | First run **failed**. The rules put write access on each day, so the cafe could not delete its whole `rep/{uid}`, and its cleanup (one atomic write) was refused entirely. Fixed (write access on `rep/$uid`, validation on each day) and redeployed. Then **2/2**, and the database is empty afterwards. |
| Screen tests `test_visual` | 10/13. `check_desktop`, `kds_desktop` and `register_desktop` differ by 0.01–0.05% of pixels. **The same 3 fail on the commit before this phase** (checked in a separate worktree), and the pixel count changes from run to run: those screens show the current time. Not caused by phase 3. The QR card PDFs were regenerated with the new site address. |
| Playwright | Not re-run: `menu.html` did not change in this phase (66/66 in round 7) |

**Still open:**

- 4 empty sign-in accounts on `orderly-cafe-28129`, left by the failed live run. Delete them in Authentication → Users.
- The rules on the new project are deployed. The customer page did not change.

Evidence: `phase3/flutter-test.log`, `phase3/stress.log`, `phase3/cloud-live.log`, `phase3/visual.log`.

## Round 9: phase 4, staff web app for iPhone (2026-11-23)

**What changed:**

- **The same Flutter app now builds for the web** (`flutter build web --release --no-web-resources-cdn`). Everything is bundled, including CanvasKit, so nothing loads from the internet.
- **The cashier PC serves it** on its own port (`lib/src/server/web_app.dart`):
  - no path traversal;
  - correct types (`application/wasm`);
  - ETag/304, `no-cache`, nosniff;
  - pages without an extension fall back to `index.html`;
  - unknown `/api/...` paths are still JSON 404;
  - a clear Arabic message when the web folder is missing.
- **App code is web-safe without changing Android/Windows:**
  - Every `Platform.*` call has a `kIsWeb` guard in front of it.
  - The embedded server is a conditional import (`server_launcher.dart`): sqlite3/ffi can't compile for the web.
  - `serverPort` moved to `app_info.dart`.
  - On the web, the session's server is the page's own origin.
  - The browser WebSocket is used on the web.
  - On the web, the app does not try to be a print station.
  - The logs screen and the barcode camera say they are not available on the web.
- **iPhone home-screen:** Arabic page, the app icon, `apple-mobile-web-app-capable`, manifest. `?a11y=1` turns on semantics, for VoiceOver users and for the tests.
- **Server settings** show a QR code and the steps for staff with an iPhone.
- `tool/build_release.ps1` puts the web build in `web/` next to the exe, so the installer ships it.

| Test | Result |
|---|---|
| `test/web_app_test.dart` | **4/4**: page, types, 304, deep links; **no file outside the web folder** (`..`, `%2e%2e`, `%2f`, `%5c`, drive letters, and a raw socket request); API unchanged; missing web folder |
| `test_web/staff` (Playwright, real server, **internet blocked**) | **4/4** on WebKit/iPhone 14 and Chromium/Pixel 7: the login screen in about 1.2 s / 1.5 s, the waiter logs in, and the floor shows the 4 tables from the server. **0 requests left the cafe PC.** No page errors. The server recorded the logins as "متصفح (ويب)". The home-screen tags, manifest and icon are served. |
| `flutter test test/` | **107/107** |
| `test_stress` | **32/32** |
| `test_visual` | 10/13: the same 3 time-dependent screenshots as round 8 |
| Builds | `flutter build windows --release` OK; `flutter build apk --release` OK (91.2 MB); `flutter build web` OK (45 MB on disk; a phone downloads only one renderer: about 5.5 MB JS + 7 MB wasm, once, over the cafe Wi-Fi) |

**Not tested:**

- **A real iPhone.** WebKit on Windows is close but not the same, especially Arabic typing with the iOS keyboard and older iPhones. Please test on a real phone.
- The installed Windows app finding `web/` next to the exe (the folder lookup is covered with an explicit folder in the tests).
- Font fallback for a character outside Cairo (for example an emoji) would try Google Fonts and, with no internet, show a box.

Evidence: `phase4/`, `staff-web/` (report, screenshots of the floor on both engines), `staff-web-run.log`, `web-build.log`.

## Round 10: phase 5, the owner app with reports, PDF and notifications (2026-11-26)

**What changed:**

- **Owner app:** a Flutter web build in owner mode at `https://orderly-cafe-28129.web.app/owner/`, the same app for iPhone and Android. Join from the QR link, branches, days, the day report, PDF per day, and a notifications switch.
- **Linking on the cashier PC:** in the main branch's settings, "المالك من بره" makes a one-time code (8 characters, 15 minutes) shown as a QR. The owner signs up on the shop's own Firebase project and claims with the code, and the PC approves the claim when the code matches, then cancels the code.
- **The main branch publishes:**
  - `own/$main/shops`: itself plus the linked branches;
  - VAPID keys;
  - and every cafe writes `cafes/$uid/main` (branches get the main's id when approved).
- **Notifications (Web Push from the cafe PC, no server, no paid plan):**
  - RFC 8291 aes128gcm + RFC 8292 VAPID (`lib/src/server/web_push.dart`).
  - One notification per shift close, and one per finished day (the last 2 days at most after downtime). Each is sent once and remembered across restarts.
  - Subscriptions the push service reports as gone (404/410) are removed.
  - Only known push services are contacted.
- **New dependency, with your approval:** `pointycastle` 4.0.0 (MIT, Bouncy Castle), pulling in `convert` 3.1.2 (Dart team). The `cryptography` package turned out not to support P-256 in pure Dart, so the study was wrong about that.
- **Rules (deployed):** the owner reads a branch's reports only when the main has confirmed that branch AND the branch points at that main. The code can't be read, reused, or claimed for someone else. The private key and the phone list are readable only by confirmed branches.
- **Web pages:**
  - custom `flutter_bootstrap.js`, without Flutter's deprecated service worker;
  - `push-sw.js`;
  - `owner_push.js`;
  - `manifest-owner.json` with no start_url, so the iPhone saves the invite link;
  - `index.html` switches the manifest under `/owner/`.
- **Offline fonts:** Cairo has no "←", "✔" or "✅", so the offline staff web app showed boxes. In screen text and the PDF, "←" is now "›" (mirrored in RTL), and "✔"/"✅" were dropped (the colour and the word stay).

| Test | Result |
|---|---|
| `test/web_push_test.dart` | **4/4**: byte-exact RFC 8291 section 5 message and appendix A ciphertext; random messages decrypt like a phone; the ES256 JWT verifies; only known push hosts |
| `test/owner_link_test.dart` (fake Firebase) | **4/4**: right code approved, wrong code not, code single-use; shops, main pointer, stable VAPID key; one push per shift close to every phone, no repeat, gone phone removed; remove owner; cashier gets 403 |
| `test_cloud/owner_cloud_test.dart` (**real Firebase, deployed rules**) | **1/1** (after a test bug was fixed: an empty PUT instead of DELETE). Wrong code, reading the code, claiming for someone else, reusing the code, the owner writing reports, a stranger reading reports, a fake branch reading the private key or phones, an owner after removal: **all refused**. The owner reads shops, the public key and the reports. Afterwards there was **no data and 0 accounts**. A leftover `cafes/<stranger>` from the interrupted first run was deleted, and the test now always cleans it up. |
| `test_web/owner` (Playwright, owner app from `firebase/public/owner`, fake Firebase) | **6/6** on WebKit/iPhone 14 and Chromium/Pixel 7: QR link, new account, linked by code, branches, days, the day report with the right numbers, PDF; a wrong code gives a clear message; a non-Firebase database in the link is refused. The notification card says "add to home screen" on iPhone Safari and offers the button on Android. |
| `test_web/staff` | **4/4** (after the bootstrap/index changes) |
| `flutter test test/` | **115/115**; `test_stress` **32/32** |
| Deploy | Rules deployed; Hosting deployed. Live: `/owner/` 200, `push-sw.js` 200, the manifest 200, the customer menu still 200 |

**Not tested:** a real notification arriving on a real iPhone or Android, which needs a real phone subscribed to Apple/Google; the encryption is verified against the RFC, but end-to-end delivery is not. Also the PDF share sheet on a real phone.

Evidence: `phase5/`, `owner-web/` (report, screenshots), `owner-build.log`.

## Round 11: phase 6, the owner sees each branch live (2026-11-26)

**What changed:**

- Every cafe (main, branch, or a cafe with no branches) sends its summary to `live/{uid}`, at most once a minute when it changed, plus a heartbeat every 5 minutes. This is the same summary the main branch already received: today by business day, open checks, busy tables, the register (who opened it, expected cash), QR orders, transfers and calls waiting, voids.
- **Rules:** same read condition as the reports (main confirmed the branch AND the branch points at that main). Only the cafe writes, with size and time validated.
- **Owner app home:** one card per branch with today, open checks, the drawer and what is waiting, plus "شغال" or "مش متصل من …" when there has been no heartbeat for 10 minutes. It refreshes every 30 s only while the app is in front of the owner. The card is a button for screen readers (VoiceOver).

| Test | Result |
|---|---|
| `test/owner_link_test.dart` | **5/5** (new: the summary is sent, throttled to once a minute, and shows the opened register on the next minute) |
| `test_cloud/owner_cloud_test.dart` (real Firebase, deployed rules) | **1/1**: the owner reads `live`; a stranger and the owner writing are refused; nothing left behind |
| `test_web/owner` | **6/6** on WebKit/iPhone and Chromium/Android: a running branch card (today 4,567 EGP, 3 open, drawer with Sara, 2 QR + 1 transfer waiting) and an offline branch card ("مش متصل من …", drawer closed). The screenshots also confirm that "›" renders correctly in RTL. |
| `flutter test test/` | **116/116** |
| Deploy | Rules and Hosting deployed; `/owner/` 200 |

**Firebase cost:** uploads are free. The owner downloads about 2 KB per branch every 30 s, and only while the app is open (about 0.4 MB for 30 minutes with 3 branches).

## Round 12: phase 7, remote control with a fixed list (2026-11-27)

**What changed:** commands over Firebase, not a tunnel into the whole API:
- **The list:** `menu.get`, `item.price`, `item.available`, `checks.open`, `audit.recent`.
- **Owner writes `cmd/{cafe}/{id}`.** The rules allow only a linked owner, only those 5 ops, `by` must be the writer, the time is the server's, and a command can't be overwritten.
- **The cashier PC listens** (one live connection, only while "التحكم من بعيد" is on, which it is not by default, per branch). It runs the command, writes `cmdr/{cafe}/{id}` (readable only by the sender) and deletes the command.
- **Refused:** commands older than 2 minutes, and more than 30 a minute.
- **Every change goes in the activity log** as "من أبلكيشن المالك".
- Owner app: in each branch, the "تحكم من بعيد" menu (menu and prices with a sold-out switch, open checks, activity log). The cashier screen has the on/off switch on every branch.

| Test | Result |
|---|---|
| `test/remote_test.dart` (fake Firebase) | **3/3**: off by default (no reply); all 5 commands; price and availability change in the database; logged "من أبلكيشن المالك"; bad price, unknown item, op outside the list, stale command refused; turned off = no listening; the 31st+ command in a minute refused |
| `test_cloud/owner_cloud_test.dart` (real Firebase) | First run: the checks passed but **the cleanup failed**. The rules didn't let a cafe delete its whole `cmd/{uid}`, and the cleanup is one atomic write, so it was refused entirely: the same class of bug as round 8. Fixed: the cafe may delete its whole `cmd/{uid}`. The leftovers (the temp cafe's data and account) were deleted using that cafe's own saved credentials. Then **1/1**: the owner sends only listed ops in his own name; stranger, fake `by`, reading the queue, reading someone else's reply, and faking a reply are all refused; the PC really answered over the deployed rules; a removed owner can't send. **Empty database and 0 accounts afterwards.** |
| `test_web/owner` | **8/8** on WebKit/iPhone and Chromium/Android (new: the remote menu, prices, and the sold-out switch sends `item.available` with the right id, signed by the owner) |
| `flutter test test/` | **119/119**; `test_stress` **32/32** |
| Deploy | Rules and Hosting deployed |

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
- `branches/` — round 5: local and live Firebase branch tests
