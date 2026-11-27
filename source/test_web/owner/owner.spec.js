// أبلكيشن المالك من أول ما بيفتح لينك الـ QR: حساب جديد، ربط بالكود، الفروع، الأيام، تقرير اليوم، والـ PDF.
// Firebase (الدخول والداتابيز) وهمي بالكامل، والأبلكيشن نفسه من firebase/public/owner (نفس اللي بيترفع).
const { test, expect } = require('@playwright/test');
const fs = require('fs');
const path = require('path');

const OUT = process.env.WEB_OUT || path.join(__dirname, '..', '..', '..', 'test-results', 'owner-web');
const APP = path.join(__dirname, '..', '..', 'firebase', 'public', 'owner');
const SITE = 'https://owner.test';
const DB = 'cafe-elnour-default-rtdb.europe-west1.firebasedatabase.app';
const MAIN = 'mainUid123';
const SHOP2 = 'branchUid456';
const CODE = 'ABCD2345';
const KEY = 'test-api-key';

const report = {
  v: 1, date: '2026-11-22', final: true, shop: 'كافيه النور', branch: 'فرع المعادي', hours: { open: '21:00', close: '03:00' },
  sales: { checks: 41, totalCents: 1245000, subtotalCents: 1100000, discountCents: 15000, discountedChecks: 3, serviceCents: 132000, taxCents: 28000, deliveryCents: 0, guests: 90, pointsUsed: 0, avgCheckCents: 30366, costCents: 410000, grossProfitCents: 690000 },
  byMethod: [{ name: 'كاش', kind: 'cash', count: 30, amountCents: 900000 }, { name: 'إنستاباي', kind: 'instapay', count: 11, amountCents: 345000 }],
  byType: [{ type: 'dine_in', count: 35, amountCents: 1100000 }, { type: 'takeaway', count: 6, amountCents: 145000 }],
  bySource: [{ source: 'qr', orders: 22 }, { source: 'waiter', orders: 30 }],
  byHour: Array.from({ length: 24 }, (_, h) => (h === 23 ? 300000 : h === 22 ? 200000 : 0)),
  expenses: { totalCents: 25000, byCategory: [{ name: 'تلج', count: 2, amountCents: 25000 }] },
  voids: { count: 1, amountCents: 6000, items: [{ name: 'لاتيه', qty: 1, amountCents: 6000, reason: 'العميل غيّر رأيه', by: 'منى' }], checks: 0, checksAmountCents: 0 },
  top: [{ name: 'شاي', qty: 60, revenueCents: 120000 }],
  feedback: { count: 4, avg: 4.5 },
  shifts: [{ id: 's1', openedAt: '2026-11-22T18:55:00Z', openedBy: 'سارة', closedAt: '2026-11-23T01:05:00Z', closedBy: 'سارة', salesCents: 1245000, checksClosed: 41, expectedCashCents: 900000, countedCashCents: 895000, diffCents: -5000, spansDays: false }],
  cash: { expectedCents: 900000, countedCents: 895000, diffCents: -5000 },
  open: null, lowStock: 2,
};

/** Firebase وهمي: الدخول، والداتابيز (بالمسار)، والمالك بيتوافق عليه بعد طلب الربط. */
async function fakeFirebase(page) {
  const db = {
    [`own/${MAIN}/shops`]: { [MAIN]: { name: 'كافيه النور', branch: 'الفرع الرئيسي' }, [SHOP2]: { name: 'كافيه النور', branch: 'فرع المعادي' } },
    [`own/${MAIN}/vapid/pub`]: 'BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8',
    [`rep/${SHOP2}`]: { '2026-11-22': true, '2026-11-21': true },
    // فرع المعادي شغال دلوقتي، والرئيسي آخر تحديث منه من ساعتين
    [`live/${SHOP2}`]: { at: Date.now(), j: JSON.stringify({ branch: 'فرع المعادي', today: { n: 12, t: 456700 }, open: { n: 3, t: 89000, busy: 3, tables: 10 }, reg: { by: 'سارة', cash: 120000 }, qr: 2, pays: 1, calls: 0, voids: 0 }) },
    [`live/${MAIN}`]: { at: Date.now() - 2 * 3600 * 1000, j: JSON.stringify({ branch: 'الفرع الرئيسي', today: { n: 0, t: 0 }, open: { n: 0, t: 0, busy: 0, tables: 8 }, reg: null, qr: 0, pays: 0, calls: 0, voids: 0 }) },
    [`rep/${SHOP2}/2026-11-22`]: { day: { j: JSON.stringify(report), at: 1 }, shifts: { s1: { j: JSON.stringify({ id: 's1' }), at: 1 } } },
  };
  const writes = [];
  await page.route('https://identitytoolkit.googleapis.com/**', (r) => {
    const body = JSON.parse(r.request().postData() || '{}');
    expect(new URL(r.request().url()).searchParams.get('key')).toBe(KEY);
    return r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ localId: 'ownerUid', idToken: 'tok', refreshToken: 'ref', email: body.email }) });
  });
  await page.route('https://securetoken.googleapis.com/**', (r) => r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id_token: 'tok', refresh_token: 'ref', expires_in: '3600' }) }));
  await page.route(`https://${DB}/**`, (r) => {
    const req = r.request();
    const p = new URL(req.url()).pathname.replace(/^\//, '').replace(/\.json$/, '');
    if (req.method() === 'PUT') {
      writes.push({ path: p, body: JSON.parse(req.postData()) });
      // الفرع الرئيسي بيوافق على طلب الربط بالكود الصح
      if (p === `own/${MAIN}/claim/ownerUid` && JSON.parse(req.postData()).c === CODE) db[`own/${MAIN}/ok/ownerUid`] = { name: 'المالك' };
      // كمبيوتر الفرع بيرد على أوامر التحكم من بعيد
      const cmd = p.match(/^cmd\/([^/]+)\/([^/]+)$/);
      if (cmd) {
        const body = JSON.parse(req.postData());
        const replies = {
          'menu.get': { items: [{ id: 'i1', n: 'لاتيه', c: 'مشروبات', p: 6000, av: true }, { id: 'i2', n: 'شاي', c: 'مشروبات', p: 2000, av: false }] },
          'item.available': { ok: true },
          'item.price': { ok: true },
          'checks.open': { checks: [{ n: 7, type: 'dine_in', t: 15000, paid: 0, at: '2026-11-26T18:00:00Z', table: '4', w: 'سارة' }] },
        };
        db[`cmdr/${cmd[1]}/${cmd[2]}`] = { ok: true, r: JSON.stringify(replies[body.op] ?? {}), by: body.by };
      }
      return r.fulfill({ status: 204, body: '' });
    }
    return r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(db[p] ?? null) });
  });
  return { writes };
}

/** الأبلكيشن من الفولدر اللي بيترفع، وCanvasKit من نسخته جوه الفولدر بدل CDN جوجل. */
async function serveApp(page) {
  await page.route(`${SITE}/owner/**`, (r) => {
    let rel = new URL(r.request().url()).pathname.replace(/^\/owner\/?/, '') || 'index.html';
    const file = path.join(APP, rel);
    if (!fs.existsSync(file) || fs.statSync(file).isDirectory()) return r.fulfill({ status: 404, body: '' });
    const type = { html: 'text/html', js: 'text/javascript', json: 'application/json', wasm: 'application/wasm', png: 'image/png', ttf: 'font/ttf', otf: 'font/otf', wav: 'audio/wav' }[rel.split('.').pop()] || 'application/octet-stream';
    return r.fulfill({ status: 200, contentType: type, body: fs.readFileSync(file) });
  });
  await page.route('https://www.gstatic.com/flutter-canvaskit/**', (r) => {
    const name = new URL(r.request().url()).pathname.split('/').slice(3).join('/');
    const file = path.join(APP, 'canvaskit', name);
    if (!fs.existsSync(file)) return r.fulfill({ status: 404, body: '' });
    return r.fulfill({ status: 200, contentType: name.endsWith('.wasm') ? 'application/wasm' : 'text/javascript', body: fs.readFileSync(file) });
  });
}

async function typeInto(page, field, text) {
  await field.click();
  await page.waitForFunction(() => ['INPUT', 'TEXTAREA'].includes(document.activeElement && document.activeElement.tagName));
  await page.keyboard.type(text, { delay: 20 });
}

const semanticsText = (page) => page.evaluate(() => {
  const h = document.querySelector('flt-semantics-host');
  return h ? h.innerText + ' ' + [...h.querySelectorAll('[aria-label]')].map((e) => e.getAttribute('aria-label')).join(' ') : '';
});

test('QR link → new account → linked by code → branches → day report → PDF', async ({ page }, ti) => {
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await serveApp(page);
  const fb = await fakeFirebase(page);
  await page.goto(`${SITE}/owner/?c=${CODE}&m=${MAIN}&k=${KEY}&d=${DB}&a11y=1`);
  await page.waitForSelector('flt-semantics[role], flt-semantics input', { state: 'attached', timeout: 90_000 });

  await expect.poll(() => semanticsText(page)).toContain('ربط المالك');
  await typeInto(page, page.getByRole('textbox', { name: 'اسمك' }), 'أحمد');
  await typeInto(page, page.getByRole('textbox', { name: 'الإيميل' }), 'owner@example.com');
  await typeInto(page, page.getByRole('textbox', { name: /كلمة السر/ }), 'secret123');
  await page.getByRole('button', { name: 'اربطني' }).click();

  // اتربط: الفروع ظهرت، وطلب الربط اتبعت بالكود الصح
  await expect.poll(() => semanticsText(page), { timeout: 60_000 }).toContain('فرع المعادي');
  // الفروع وهي شغالة
  await expect.poll(() => semanticsText(page)).toContain('4,567');
  const home = await semanticsText(page);
  expect(home).toContain('مفتوح دلوقتي: 3 حساب');
  expect(home).toContain('الدرج مفتوح مع سارة');
  expect(home).toContain('2 طلب QR');
  expect(home).toContain('مش متصل من');
  expect(home).toContain('الدرج مقفول');
  await page.screenshot({ path: path.join(OUT, `owner-home-${ti.project.name}.png`) });
  const claim = fb.writes.find((w) => w.path === `own/${MAIN}/claim/ownerUid`);
  expect(claim.body.c).toBe(CODE);
  expect(claim.body.name).toBe('أحمد');
  ti.annotations.push({ type: 'push-card', description: (await semanticsText(page)).match(/(إشعار مع كل قفل وردية|على الأيفون: ضيف الصفحة|المتصفح ده مابيدعمش)/)?.[0] || 'none' });

  // الفرع ← الأيام ← تقرير اليوم
  await page.getByRole('button', { name: /فرع المعادي/ }).first().click();
  await expect.poll(() => semanticsText(page)).toContain('2026-11-22');
  await page.getByRole('button', { name: /2026-11-22/ }).click();
  await expect.poll(() => semanticsText(page), { timeout: 30_000 }).toContain('المبيعات');
  const txt = await semanticsText(page);
  expect(txt).toContain('12,450');
  expect(txt).toContain('ناقص');
  expect(txt).toContain('إنستاباي');
  await page.screenshot({ path: path.join(OUT, `owner-day-${ti.project.name}.png`) });

  // PDF: بيتعمل من غير أخطاء (بيروح لقايمة المشاركة أو بيتنزل)
  // زرار الـ PDF فوق في الشريط: Playwright على WebKit بيحسبه بره الشاشة (طبقة الـ accessibility بتاعة Flutter)، فبنبعت الضغطة للعنصر نفسه
  await page.getByRole('button', { name: 'PDF' }).dispatchEvent('click');
  await page.waitForTimeout(4000);
  expect(errors.filter((e) => !/share|AbortError|NotAllowedError/i.test(e)), errors.join('\n')).toEqual([]);
});

test('wrong or old code: clear message, nothing saved', async ({ page }) => {
  await serveApp(page);
  await fakeFirebase(page);
  await page.route(`https://${DB}/own/${MAIN}/claim/**`, (r) => r.fulfill({ status: 401, body: '{"error":"Permission denied"}' }));
  await page.goto(`${SITE}/owner/?c=ZZZZ2222&m=${MAIN}&k=${KEY}&d=${DB}&a11y=1`);
  await page.waitForSelector('flt-semantics[role], flt-semantics input', { state: 'attached', timeout: 90_000 });
  await typeInto(page, page.getByRole('textbox', { name: 'اسمك' }), 'حد');
  await typeInto(page, page.getByRole('textbox', { name: 'الإيميل' }), 'x@example.com');
  await typeInto(page, page.getByRole('textbox', { name: /كلمة السر/ }), 'secret123');
  await page.getByRole('button', { name: 'اربطني' }).click();
  await expect.poll(() => semanticsText(page), { timeout: 30_000 }).toContain('الكود خلص');
});

test('a link that is not a Firebase database is refused (shows the "no link" screen)', async ({ page }) => {
  await serveApp(page);
  await page.goto(`${SITE}/owner/?c=${CODE}&m=${MAIN}&k=${KEY}&d=evil.example.com&a11y=1`);
  // الشاشة دي كلام بس (مفيش زراير ولا خانات)
  await expect.poll(() => semanticsText(page), { timeout: 90_000 }).toContain('الفرع الرئيسي');
  expect(await semanticsText(page)).not.toContain('ربط المالك');
});

test('remote control: menu and prices, sold out switch, open checks', async ({ page }) => {
  await serveApp(page);
  const fb = await fakeFirebase(page);
  await page.addInitScript(([k, v]) => localStorage.setItem('flutter.owner_link', JSON.stringify(JSON.stringify(v))),
    ['x', { k: KEY, d: DB, m: MAIN, u: 'ownerUid', e: 'o@x', r: 'ref' }]);
  await page.goto(`${SITE}/owner/?a11y=1`);
  await expect.poll(() => semanticsText(page), { timeout: 90_000 }).toContain('فرع المعادي');
  await page.getByRole('button', { name: /فرع المعادي/ }).first().click();
  // زرار في الشريط فوق: نفس طريقة زرار الـ PDF
  await page.getByRole('button', { name: 'تحكم من بعيد' }).dispatchEvent('click');
  await expect.poll(() => semanticsText(page)).toContain('المنيو والأسعار');
  await page.getByRole('menuitem', { name: /المنيو والأسعار/ }).or(page.getByRole('button', { name: /المنيو والأسعار/ })).first().dispatchEvent('click');
  await expect.poll(() => semanticsText(page), { timeout: 30_000 }).toContain('لاتيه');
  expect(await semanticsText(page)).toContain('60');
  await page.getByRole('switch').first().dispatchEvent('click');
  await expect.poll(() => fb.writes.some((w) => w.path.startsWith(`cmd/${SHOP2}/`) && w.body.op === 'item.available')).toBe(true);
  const w = fb.writes.find((x) => x.body.op === 'item.available');
  expect(JSON.parse(w.body.a)).toEqual({ id: 'i1', av: false });
  expect(w.body.by).toBe('ownerUid');
});
