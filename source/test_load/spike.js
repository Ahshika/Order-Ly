// أسوأ سيناريو ضغط لـ Order Ly بـ k6: "زحمة مفاجئة" + أجهزة بتبعت حاجات غلط في نفس الوقت.
// - من 0 لـ 400 جهاز في 5 ثواني، دقيقة كاملة، وبعدين قفزة تانية لـ 600 (أكتر من عدد الترابيزات، فأجهزة بتشتغل على نفس الحساب).
// - كل جهاز: يضيف طلبات، يدفع ويقفل، يقرا شاشة المطبخ والصالة.
// - 10% من الطلبات "بايظة": JSON غلط، أنواع غلط، توكن غلط، body كبير (2 ميجا).
// المهم: ولا رد 5xx ولا اتصال يقع، والسيرفر يفضل يرد بسرعة. ردود 4xx متوقعة (حساب اتقفل من جهاز تاني، بيانات غلط).
import http from 'k6/http';
import exec from 'k6/execution';
import { check } from 'k6';
import { Counter, Trend } from 'k6/metrics';

const seed = JSON.parse(open(__ENV.SEED));
const H = { headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${seed.token}` }, timeout: '30s' };

// 4xx مش فشل في السيرفر: الحساب ممكن يكون اتقفل من جهاز تاني، أو الطلب نفسه غلط عن قصد
http.setResponseCallback(http.expectedStatuses({ min: 200, max: 499 }));

const serverErrors = new Counter('server_errors');
const conflicts = new Counter('expected_conflicts');
const junkRejected = new Counter('junk_rejected');
const orderTime = new Trend('order_time', true);
const screenTime = new Trend('screen_time', true);

export const options = {
  scenarios: {
    spike: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '5s', target: 400 },
        { duration: '60s', target: 400 },
        { duration: '5s', target: 50 },
        { duration: '10s', target: 50 },
        { duration: '3s', target: 600 },
        { duration: '30s', target: 600 },
        { duration: '5s', target: 0 },
      ],
      gracefulRampDown: '10s',
      exec: 'chaos',
    },
  },
  thresholds: {
    server_errors: ['count<1'],
    http_req_failed: ['rate<0.001'],
    order_time: ['p(95)<1500'],
    screen_time: ['p(95)<1500'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

const pick = (a) => a[Math.floor(Math.random() * a.length)];
const big = 'x'.repeat(2 * 1024 * 1024);

function track(res) {
  if (res.status >= 500 || res.status === 0) {
    serverErrors.add(1);
    console.warn(`5xx/drop ${res.request.method} ${res.url} status=${res.status} ${String(res.body || res.error).slice(0, 160)}`);
  } else if (res.status >= 400) {
    conflicts.add(1);
  }
  return res;
}

function lines() {
  const out = [];
  for (let i = 0, n = 1 + Math.floor(Math.random() * 3); i < n; i++) {
    const it = pick(seed.items);
    const l = { itemId: it.id, qty: 1 + Math.floor(Math.random() * 3) };
    if (it.mods) l.modifierIds = [pick(seed.sizes)];
    out.push(l);
  }
  return out;
}

function junk() {
  const r = Math.random();
  let res;
  if (r < 0.2) res = http.post(`${seed.base}/api/checks`, '{"type":', H);
  else if (r < 0.4) res = http.post(`${seed.base}/api/checks`, JSON.stringify({ type: 5, tableId: { x: 1 }, guests: 'many' }), H);
  else if (r < 0.6) res = http.get(`${seed.base}/api/register`, { headers: { Authorization: 'Bearer nope' }, timeout: '30s' });
  else if (r < 0.8) res = http.post(`${seed.base}/api/auth/login`, JSON.stringify({ username: big, password: big }), { headers: { 'Content-Type': 'application/json' }, timeout: '30s' });
  else res = http.post(`${seed.base}/api/checks/${pick(seed.tables)}/orders`, JSON.stringify({ lines: [{ itemId: 7, qty: 'x' }] }), H);
  track(res);
  if (res.status >= 400 && res.status < 500) junkRejected.add(1);
}

export function chaos() {
  if (Math.random() < 0.1) return junk();

  const roll = Math.random();
  if (roll < 0.25) {
    for (const path of ['/api/kds', '/api/floor', '/api/live']) {
      const t0 = Date.now();
      track(http.get(`${seed.base}${path}`, Object.assign({ tags: { name: path } }, H)));
      screenTime.add(Date.now() - t0);
    }
    return;
  }

  // أكتر من جهاز ممكن ياخدوا نفس الترابيزة (600 جهاز على 310 ترابيزة)
  const table = seed.tables[(exec.vu.idInTest - 1) % seed.tables.length];
  const open = track(http.post(`${seed.base}/api/checks`, JSON.stringify({ type: 'dine_in', tableId: table }), H));
  if (open.status !== 200) return;
  const checkId = open.json('check.id');

  const t0 = Date.now();
  const res = track(http.post(`${seed.base}/api/checks/${checkId}/orders`, JSON.stringify({ lines: lines() }), Object.assign({ tags: { name: 'add order' } }, H)));
  orderTime.add(Date.now() - t0);
  if (res.status !== 200) return;

  if (Math.random() < 0.4) {
    const c = res.json('check');
    const pay = track(http.post(`${seed.base}/api/checks/${checkId}/payments`, JSON.stringify({ methodId: seed.cash, amountCents: c.totalCents - c.paidCents, close: true }), H));
    check(pay, { 'pay ok or conflict': (r) => r.status === 200 || r.status === 400 });
  }
}
