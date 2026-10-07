// اختبار ضغط لـ Order Ly بـ k6 (أداة Grafana).
// 5 دقايق: بيبدأ بـ 500 طلب في الدقيقة ويزود 500 كل 15 ثانية لحد 10000 طلب في الدقيقة.
// "الطلب" = الكاشير/الويتر بيضيف أوردر على حساب (ترابيزة أو تيك أواي)، وكل شوية الحساب بيتدفع ويتقفل.
// وفي نفس الوقت 3 شاشات (كاشير + مطبخ + ويتر) بيحدّثوا كل ثانية زي البرنامج الحقيقي.
import http from 'k6/http';
import exec from 'k6/execution';
import { check, sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';

const seed = JSON.parse(open(__ENV.SEED));
const H = { headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${seed.token}` }, timeout: '30s' };

const ordersOk = new Counter('orders_ok');
const ordersFailed = new Counter('orders_failed');
const orderTime = new Trend('order_time', true);
const closeTime = new Trend('close_time', true);
const screenTime = new Trend('screen_time', true);

const STEP = 15; // ثانية لكل مرحلة
const stages = [];
for (let i = 1; i <= 20; i++) {
  stages.push({ duration: '1s', target: 500 * i });
  stages.push({ duration: `${STEP - 1}s`, target: 500 * i });
}

export const options = {
  scenarios: {
    orders: {
      executor: 'ramping-arrival-rate',
      startRate: 500,
      timeUnit: '1m',
      preAllocatedVUs: 50,
      maxVUs: 300, // = عدد الترابيزات، عشان مفيش اتنين يشتغلوا على نفس الترابيزة
      stages,
      exec: 'order',
    },
    screens: {
      executor: 'constant-vus',
      vus: 3,
      duration: `${STEP * 20}s`,
      exec: 'screens',
    },
  },
  thresholds: {
    order_time: ['p(95)<500'],
    orders_failed: ['count<1'],
    http_req_failed: ['rate<0.01'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

const pick = (a) => a[Math.floor(Math.random() * a.length)];

function lines() {
  const n = 1 + Math.floor(Math.random() * 3);
  const out = [];
  for (let i = 0; i < n; i++) {
    const it = pick(seed.items);
    const l = { itemId: it.id, qty: 1 + Math.floor(Math.random() * 2) };
    if (it.mods) l.modifierIds = Math.random() < 0.5 ? [pick(seed.sizes)] : [pick(seed.sizes), pick(seed.extras)];
    out.push(l);
  }
  return out;
}

function fail(stage, res) {
  ordersFailed.add(1, { stage });
  console.warn(`FAIL ${stage} status=${res.status} ${String(res.body || res.error).slice(0, 200)}`);
}

// حالة كل مستخدم وهمي: الحساب المفتوح على ترابيزته وعدد الطلبات عليه
let myCheck = null;
let myOrders = 0;
let myLimit = 0;

function payAndClose(checkId, total, paid) {
  const due = total - paid;
  const t0 = Date.now();
  const res = http.post(`${seed.base}/api/checks/${checkId}/payments`, JSON.stringify({ methodId: seed.cash, amountCents: due, close: true }), H);
  closeTime.add(Date.now() - t0);
  if (!check(res, { 'closed': (r) => r.status === 200 })) fail('close', res);
}

export function order() {
  const dineIn = Math.random() < 0.6;
  let checkId;
  if (dineIn && myCheck) {
    checkId = myCheck;
  } else {
    const body = dineIn
      ? { type: 'dine_in', tableId: seed.tables[(exec.vu.idInTest - 1) % seed.tables.length], guests: 2 }
      : { type: 'takeaway', customerName: 'عميل' };
    const res = http.post(`${seed.base}/api/checks`, JSON.stringify(body), H);
    if (!check(res, { 'check opened': (r) => r.status === 200 })) return fail('open', res);
    checkId = res.json('check.id');
    if (dineIn) {
      myCheck = checkId;
      myOrders = 0;
      myLimit = 2 + Math.floor(Math.random() * 4);
    }
  }

  const t0 = Date.now();
  const res = http.post(`${seed.base}/api/checks/${checkId}/orders`, JSON.stringify({ lines: lines() }), Object.assign({ tags: { name: 'add order' } }, H));
  orderTime.add(Date.now() - t0);
  if (!check(res, { 'order added': (r) => r.status === 200 })) {
    if (dineIn) myCheck = null;
    return fail('order', res);
  }
  ordersOk.add(1);
  const c = res.json('check');

  if (!dineIn) return payAndClose(checkId, c.totalCents, c.paidCents);
  myOrders++;
  if (myOrders >= myLimit) {
    payAndClose(checkId, c.totalCents, c.paidCents);
    myCheck = null;
  }
}

// الشاشات اللي فاتحة طول الوقت: الصالة، الحسابات المفتوحة، المطبخ، الأرقام اللايف
export function screens() {
  for (const path of ['/api/floor', '/api/checks', '/api/kds', '/api/live']) {
    const t0 = Date.now();
    const res = http.get(`${seed.base}${path}`, Object.assign({ tags: { name: path } }, H));
    screenTime.add(Date.now() - t0, { screen: path });
    check(res, { 'screen ok': (r) => r.status === 200 });
  }
  sleep(1);
}
