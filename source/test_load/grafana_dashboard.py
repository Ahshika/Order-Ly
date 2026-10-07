"""يبني داشبورد جرافانا من series.csv و stages.csv (البيانات جوه الداشبورد نفسه عن طريق TestData)."""
import csv, io, json, sys

run = sys.argv[1]
label = sys.argv[2] if len(sys.argv) > 2 else ''
series = list(csv.DictReader(open(f'{run}/series.csv', encoding='utf-8')))
stages = list(csv.DictReader(open(f'{run}/stages.csv', encoding='utf-8')))
DS = {'type': 'grafana-testdata-datasource', 'uid': '${DS_TESTDATA}'}

def csv_of(rows, cols):
    b = io.StringIO()
    w = csv.writer(b, lineterminator='\n')
    w.writerow(cols)
    for r in rows:
        w.writerow([r[c] for c in cols])
    return b.getvalue()

def ts_panel(pid, title, cols, unit, x, y, w=12, h=8, thresholds=None):
    p = {
        'id': pid, 'type': 'timeseries', 'title': title, 'datasource': DS,
        'gridPos': {'x': x, 'y': y, 'w': w, 'h': h},
        'targets': [{'refId': 'A', 'datasource': DS, 'scenarioId': 'csv_content', 'csvContent': csv_of(series, ['time'] + cols)}],
        'fieldConfig': {'defaults': {'unit': unit, 'custom': {'lineWidth': 2, 'fillOpacity': 10}}, 'overrides': []},
        'options': {'legend': {'displayMode': 'list', 'placement': 'bottom'}, 'tooltip': {'mode': 'multi'}},
    }
    if thresholds:
        p['fieldConfig']['defaults']['thresholds'] = {'mode': 'absolute', 'steps': [{'color': 'green', 'value': None}, {'color': 'red', 'value': thresholds}]}
        p['fieldConfig']['defaults']['custom']['thresholdsStyle'] = {'mode': 'line'}
    return p

panels = [
    ts_panel(1, 'الطلبات في الدقيقة: المطلوب مقابل اللي اتنفذ فعلاً', ['target_per_min', 'orders_per_min'], 'short', 0, 0, 24),
    ts_panel(2, 'وقت إضافة الطلب (ms)', ['order_p50_ms', 'order_p95_ms', 'order_max_ms'], 'ms', 0, 8, thresholds=500),
    ts_panel(3, 'وقت تحديث الشاشات (الصالة/المطبخ) p95', ['screen_p95_ms'], 'ms', 12, 8, thresholds=1000),
    ts_panel(4, 'تهنيج السيرفر (تأخير الـ event loop)', ['server_lag_ms'], 'ms', 0, 16, thresholds=200),
    ts_panel(5, 'الطلبات اللي فشلت', ['failed'], 'short', 12, 16),
    ts_panel(6, 'رامات السيرفر (MB)', ['rss_mb'], 'decmbytes', 0, 24),
    ts_panel(7, 'حجم قاعدة البيانات (MB)', ['db_mb'], 'decmbytes', 12, 24),
    {
        'id': 8, 'type': 'table', 'title': 'ملخص كل مرحلة (15 ثانية)', 'datasource': DS,
        'gridPos': {'x': 0, 'y': 32, 'w': 24, 'h': 14},
        'targets': [{'refId': 'A', 'datasource': DS, 'scenarioId': 'csv_content', 'csvContent': csv_of(stages, list(stages[0]))}],
        'fieldConfig': {'defaults': {}, 'overrides': []}, 'options': {'showHeader': True},
    },
]

t0, t1 = series[0]['time'], series[-1]['time']
dash = {
    '__inputs': [{'name': 'DS_TESTDATA', 'label': 'TestData', 'type': 'datasource', 'pluginId': 'grafana-testdata-datasource', 'pluginName': 'TestData'}],
    'title': f'Order Ly {label} — اختبار الضغط (500 → 10000 طلب/دقيقة)'.replace('  ', ' '),
    'uid': 'orderly-load-' + (label.replace('.', '-') or 'test'),
    'schemaVersion': 39,
    'time': {'from': t0, 'to': t1},
    'timezone': 'browser',
    'panels': panels,
    'tags': ['orderly', 'k6'],
}
json.dump(dash, open(f'{run}/grafana-dashboard.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
print('ok')
