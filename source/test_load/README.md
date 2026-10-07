# Load test (k6 + Grafana)

5 minutes, starting at **500 orders/min** and adding 500 every 15 s up to **10,000 orders/min**.
An "order" is a cashier/waiter adding an order to a table or takeaway check; checks are paid and closed along the way,
while 3 screens (floor, kitchen display, live counters) refresh every second.

The server under test is the real Order Ly server running on a **temporary folder** (port 18790) — it never touches a cafe's data.

```
cd source
powershell -ExecutionPolicy Bypass -File test_load\run.ps1 -K6 C:\path\to\k6.exe
```

Output: `k6-report.html` (open in a browser) and `grafana-dashboard.json`
(Grafana → Connections → add **TestData**, then Dashboards → New → Import → pick TestData).

| File | |
|---|---|
| `load_server_test.dart` | Starts the isolated server, seeds 40 items / 310 tables, records event-loop lag, RAM and DB size every second. |
| `orders.js` | The k6 scenario. |
| `analyze.py` | Per-stage summary (`stages.csv`) and 5-second series (`series.csv`). |
| `grafana_dashboard.py` | Builds the importable Grafana dashboard from those CSVs. |

## Results (same laptop runs both the server and k6)

| | 1.0.5 (before) | 1.0.6 (after) |
|---|---|---|
| Orders completed | 25,517 | 26,027 |
| Failed requests | 27 | **0** |
| Order time p95 | 968 ms | **236 ms** |
| Screens p95 / max | 210 ms / 5.6 s | **97 ms / 1.0 s** |
| Kitchen display at 10,000/min (median) | 5.2 s | **0.33 s** |
| Smooth up to | ~6,500/min (1 s stall at 7,000) | ~8,500/min, still serving 9,600/min at the end |

Fixes in 1.0.6:
- **Kitchen display** loaded each order with 4 extra queries (5 s at peak). Now 2 queries in total, capped at the oldest 200 orders.
- **Pay & close**: if an order was added after the cashier saw the total, the payment used to be saved while the close failed.
  Now nothing is saved and the cashier sees the new remaining amount.

Raw numbers: `results/1.0.5-before`, `results/1.0.6-after`.
