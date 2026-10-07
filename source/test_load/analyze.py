"""يلخص نتيجة k6 + قياسات السيرفر لكل مرحلة (15 ثانية) ويطلع CSV لجرافانا."""
import csv, json, sys, statistics
from collections import defaultdict
from datetime import datetime

run = sys.argv[1]
STEP = 15

def pct(v, p):
    if not v:
        return 0
    v = sorted(v)
    return v[min(len(v) - 1, int(round(p / 100 * (len(v) - 1))))]

rows = defaultdict(lambda: defaultdict(list))
t0 = None
with open(f'{run}/k6.csv', newline='', encoding='utf-8') as f:
    for r in csv.DictReader(f):
        ts = float(r['timestamp'])
        if t0 is None:
            t0 = ts
        sec = int(ts - t0)
        m = r['metric_name']
        if m in ('order_time', 'close_time', 'screen_time'):
            rows[sec][m].append(float(r['metric_value']))
        elif m == 'orders_ok':
            rows[sec]['ok'].append(1)
        elif m == 'orders_failed':
            rows[sec]['failed'].append(1)
        elif m == 'http_req_failed' and r['metric_value'] == '1':
            rows[sec]['http_err'].append(1)

lag = {}
with open(f'{run}/server_metrics.csv', encoding='utf-8') as f:
    for r in csv.DictReader(f):
        ts = datetime.fromisoformat(r['time'].replace('Z', '+00:00')).timestamp()
        lag[int(ts - t0)] = r

def window(a, b):
    acc = defaultdict(list)
    for s in range(a, b):
        for k, v in rows.get(s, {}).items():
            acc[k].extend(v)
    srv = [lag[s] for s in range(a, b) if s in lag]
    return acc, srv

stages = []
for i in range(20):
    a, b = i * STEP, (i + 1) * STEP
    acc, srv = window(a, b)
    stages.append({
        'stage': i + 1,
        'target_per_min': 500 * (i + 1),
        'orders_ok': len(acc['ok']),
        'actual_per_min': round(len(acc['ok']) * 60 / STEP),
        'failed': len(acc['failed']),
        'http_errors': len(acc['http_err']),
        'order_p50': round(pct(acc['order_time'], 50)),
        'order_p95': round(pct(acc['order_time'], 95)),
        'order_p99': round(pct(acc['order_time'], 99)),
        'order_max': round(max(acc['order_time'], default=0)),
        'close_p95': round(pct(acc['close_time'], 95)),
        'screen_p95': round(pct(acc['screen_time'], 95)),
        'screen_max': round(max(acc['screen_time'], default=0)),
        'server_lag_max': max((int(s['loop_lag_ms']) for s in srv), default=0),
        'rss_mb': max((float(s['rss_mb']) for s in srv), default=0),
        'db_mb': max((float(s['db_mb']) + float(s['wal_mb']) for s in srv), default=0),
    })

with open(f'{run}/stages.csv', 'w', newline='', encoding='utf-8') as f:
    w = csv.DictWriter(f, fieldnames=list(stages[0]))
    w.writeheader()
    w.writerows(stages)

# سلسلة كل 5 ثواني لجرافانا
series = []
end = max(rows) + 1
for a in range(0, end, 5):
    acc, srv = window(a, a + 5)
    series.append({
        'time': datetime.utcfromtimestamp(t0 + a).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'target_per_min': 500 * min(20, a // STEP + 1),
        'orders_per_min': len(acc['ok']) * 12,
        'failed': len(acc['failed']),
        'order_p50_ms': round(pct(acc['order_time'], 50)),
        'order_p95_ms': round(pct(acc['order_time'], 95)),
        'order_max_ms': round(max(acc['order_time'], default=0)),
        'screen_p95_ms': round(pct(acc['screen_time'], 95)),
        'server_lag_ms': max((int(s['loop_lag_ms']) for s in srv), default=0),
        'rss_mb': max((float(s['rss_mb']) for s in srv), default=0),
        'db_mb': round(max((float(s['db_mb']) + float(s['wal_mb']) for s in srv), default=0), 2),
    })
with open(f'{run}/series.csv', 'w', newline='', encoding='utf-8') as f:
    w = csv.DictWriter(f, fieldnames=list(series[0]))
    w.writeheader()
    w.writerows(series)

for s in stages:
    print(s)
