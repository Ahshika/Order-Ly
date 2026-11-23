// منيو العميل (QR) في أسوأ الظروف: بيانات من السيرفر الحقيقي (fixture.json)، وFirebase وهمي.
const { test, expect } = require('@playwright/test');
const fs = require('fs');
const path = require('path');

const OUT = process.env.WEB_OUT;
const fx = JSON.parse(fs.readFileSync(path.join(OUT, 'fixture.json'), 'utf8'));
const MENU_HTML = fs.readFileSync(path.join(__dirname, '..', 'firebase', 'public', 'menu.html'), 'utf8');
const DB = 'https://orderly-yvzug-default-rtdb.europe-west1.firebasedatabase.app';
const SITE = 'https://menu.test';

const item = (name) => fx.menu.items.find((i) => i.n === name);
const opt = (group, name) => fx.menu.groups.find((g) => g.n === group).o.find((o) => o.n === name);
const wallet = () => fx.pub.pay.find((p) => p.k === 'wallet');

/** Firebase وهمي. [o] بيغيّر أي جزء من البيانات أو يكسر النت. */
async function mock(page, testInfo, o = {}) {
  const sent = [];
  /** كل طلب للداتابيز وحجم رده (التنزيل اللي Firebase بيحاسب عليه). */
  const reqs = [];
  const pub = { ...fx.pub, ...(o.pub || {}) };
  const menu = o.menu || fx.menu;
  const tables = o.tables || fx.tables;
  await page.route(`${SITE}/**`, (r) => {
    const u = new URL(r.request().url());
    if (u.pathname.startsWith('/m/')) return r.fulfill({ status: 200, contentType: 'text/html; charset=utf-8', body: MENU_HTML });
    return r.fulfill({ status: 404, body: '' });
  });
  await page.route(`${DB}/**`, async (r) => {
    const req = r.request();
    const p = new URL(req.url()).pathname.replace(/^\//, '').replace(/\.json$/, '');
    if (o.down) return r.fulfill({ status: 503, body: 'down' });
    if (o.delayMs) await new Promise((res) => setTimeout(res, o.delayMs));
    if (req.method() === 'PUT') {
      if (o.failPut) return r.abort('internetdisconnected');
      const body = JSON.parse(req.postData() || 'null');
      sent.push({ path: p, body });
      return r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) });
    }
    const parts = p.split('/');
    const stream = (req.headers()['accept'] || '').includes('text/event-stream');
    let data = null;
    if (parts[0] === 'cafes' && parts[1] === fx.cafe) {
      if (parts[2] === 'pub') data = pub;
      else if (parts[2] === 'menu') data = menu;
      else if (parts[2] === 'logo') data = o.logo ?? null;
      else if (parts[2] === 'mv') data = menu.v;
      else if (parts[2] === 'seen') data = o.seen ?? Date.now();
      else if (parts[2] === 'tables') data = tables[parts[3]] ?? null;
    } else if (parts[0] === 'trackc') data = o.trackc ?? null;
    else if (parts[0] === 'trackt') data = o.trackt ?? null;
    // EventSource: نبعت الحالة كلها مرة واحدة زي Firebase
    if (stream) {
      const body = `event: put\ndata: ${JSON.stringify({ path: '/', data })}\n\n`;
      reqs.push({ path: p, stream, bytes: body.length });
      return r.fulfill({ status: 200, contentType: 'text/event-stream', body });
    }
    const body = JSON.stringify(data);
    reqs.push({ path: p, stream, bytes: body.length });
    return r.fulfill({ status: 200, contentType: 'application/json', body });
  });
  page.on('pageerror', (e) => testInfo.annotations.push({ type: 'pageerror', description: String(e) }));
  return {
    sent,
    reqs,
    /** بيحفظ الرسايل اللي اتبعتت عشان السيرفر الحقيقي ياخدها بعد كده (menu_contract_test.dart). */
    save(testName) {
      const dir = path.join(OUT, 'captured');
      fs.mkdirSync(dir, { recursive: true });
      for (const s of sent.filter((x) => x.path.startsWith('inbox/'))) {
        const id = s.path.split('/')[2];
        const proof = sent.find((x) => x.path === `proof/${fx.cafe}/${id}`);
        fs.writeFileSync(path.join(dir, `${testInfo.project.name}-${id}.json`), JSON.stringify({ id, test: testName, browser: testInfo.project.name, inbox: s.body, proof: proof ? proof.body : null }));
      }
    },
  };
}

const open = (page, key = fx.tableKey) => page.goto(`${SITE}/m/${fx.cafe}/${key}`);
const toast = (page) => page.locator('.toast').last();

async function addLatte(page, qty = 1) {
  await page.locator(`[data-item="${item('لاتيه').id}"]`).click();
  const add = page.locator('#addBtn');
  await expect(add).toBeDisabled(); // الحجم إجباري
  await page.locator(`.opt[data-o="${opt('الحجم', 'كبير').id}"]`).click();
  await page.locator(`.opt[data-o="${opt('إضافات', 'شوت').id}"]`).click();
  for (let i = 1; i < qty; i++) await page.locator('#qp').click();
  await expect(add).toBeEnabled();
  await add.click();
  const no = page.locator('#noThanks');
  if (await no.isVisible().catch(() => false)) await no.click();
}

async function fillContact(page, name = 'سلمى', phone = '٠١٠١٢٣٤٥٦٧٨') {
  await page.locator('#cname').fill(name);
  await page.locator('#cphone').fill(phone);
}

test('loads the real menu in Arabic, right-to-left', async ({ page }, ti) => {
  await mock(page, ti);
  await open(page);
  await expect(page.locator('#cafeName')).toHaveText(fx.pub.name);
  await expect(page.locator('html')).toHaveAttribute('dir', 'rtl');
  await expect(page.locator('#placeName')).toContainText('1');
  await expect(page.locator('.item')).toHaveCount(fx.menu.items.length);
});

test('required size, quantity and extras: price math matches the server', async ({ page }, ti) => {
  await mock(page, ti);
  await open(page);
  await addLatte(page, 2);
  // (60 + كبير 15 + شوت 10) × 2 = 170 جنيه
  await expect(page.locator('#cartN')).toHaveText('2');
  await expect(page.locator('#cartT')).toContainText('170');
});

test('contact validation, then an order the real server accepts', async ({ page }, ti) => {
  const fb = await mock(page, ti);
  await open(page);
  await addLatte(page);
  await page.locator('#cartbar').click();
  await page.locator('#sendBtn').click();
  await expect(toast(page)).toHaveText('اكتب اسمك');
  await page.locator('#cname').fill('سلمى');
  await page.locator('#cphone').fill('123');
  await page.locator('#sendBtn').click();
  await expect(toast(page)).toContainText('رقم موبايل');
  await fillContact(page);
  await page.locator('#sendBtn').click();
  await expect(page.locator('.toast', { hasText: 'الطلب اتبعت' })).toBeVisible();
  const inbox = fb.sent.find((s) => s.path.startsWith('inbox/'));
  expect(inbox.body.t).toBe('order');
  expect(inbox.body.k).toBe(fx.tableKey);
  expect(inbox.body.at).toEqual({ '.sv': 'timestamp' });
  expect(inbox.body.j.length).toBeLessThanOrEqual(12000); // حد قواعد Firebase
  fb.save('order');
});

test('wallet payment: needs a screenshot, a 12 MP photo is shrunk under the Firebase 1.2 MB limit', async ({ page }, ti) => {
  const fb = await mock(page, ti);
  await open(page);
  await addLatte(page);
  await page.locator('#cartbar').click();
  await fillContact(page);
  await page.locator(`[data-pm="${wallet().id}"]`).click();
  await page.locator('#sendBtn').click();
  await expect(toast(page)).toHaveText('ارفع صورة التحويل الأول');
  // صورة 4000×3000 بنويز عشوائي (أسوأ حالة للضغط)
  const b64 = await page.evaluate(() => {
    const c = document.createElement('canvas'); c.width = 4000; c.height = 3000;
    const g = c.getContext('2d'); const d = g.createImageData(4000, 3000);
    for (let i = 0; i < d.data.length; i++) d.data[i] = (Math.random() * 256) | 0;
    g.putImageData(d, 0, 0);
    return c.toDataURL('image/png').split(',')[1];
  });
  await page.locator('#proofIn').setInputFiles({ name: 'transfer.png', mimeType: 'image/png', buffer: Buffer.from(b64, 'base64') });
  await expect(page.locator('label.upl img')).toBeVisible({ timeout: 30_000 });
  await fillContact(page);
  await page.locator('#sendBtn').click();
  await expect(page.locator('.toast', { hasText: 'الطلب اتبعت' })).toBeVisible();
  const proof = fb.sent.find((s) => s.path.startsWith('proof/'));
  ti.annotations.push({ type: 'proof', description: `original PNG ${(b64.length * 0.75 / 1048576).toFixed(1)} MB → uploaded ${(proof.body.d.length / 1024).toFixed(0)} KB` });
  expect(proof.body.d.length).toBeLessThanOrEqual(1_200_000);
  // صورة كلها ضوضاء (أسوأ حالة): بتنزل لأقل جودة. صورة تحويل حقيقية بتطلع أقل من 300 كيلو (اختبار تحت)
  expect(proof.body.d.length).toBeLessThanOrEqual(450_000);
  expect(fb.sent.find((s) => s.path.startsWith('inbox/')).body.p).toBe(true);
  fb.save('wallet+proof');
});

test('takeaway QR: no waiter button, order still goes through', async ({ page }, ti) => {
  const fb = await mock(page, ti);
  await open(page, fx.takeawayKey);
  await expect(page.locator('#placeName')).toContainText('تيك أواي');
  await expect(page.locator('#waiterFab')).toBeHidden();
  await page.locator(`[data-item="${item('تشيز كيك').id}"]`).click();
  await page.locator('#addBtn').click();
  await page.locator('#cartbar').click();
  await fillContact(page, 'كريم', '01112345678');
  await page.locator('#sendBtn').click();
  await expect(page.locator('.toast', { hasText: 'الطلب اتبعت' })).toBeVisible();
  fb.save('takeaway');
});

test('wrong / old table code', async ({ page }, ti) => {
  await mock(page, ti);
  await open(page, 'not-a-real-key');
  await expect(page.locator('main')).toContainText('الكود ده مش شغال');
});

test('cafe paused mobile ordering: menu visible, sending disabled', async ({ page }, ti) => {
  await mock(page, ti, { pub: { open: false } });
  await open(page);
  await expect(page.locator('.banner.warn')).toContainText('مش بيستقبل');
  await addLatte(page);
  await page.locator('#cartbar').click();
  await expect(page.locator('#sendBtn')).toBeDisabled();
});

test('cashier PC off for an hour: offline banner', async ({ page }, ti) => {
  await mock(page, ti, { seen: Date.now() - 60 * 60 * 1000 });
  await open(page);
  await expect(page.locator('.banner.warn')).toContainText('مش متصل');
});

test('internet drops while sending: error shown, cart kept, can retry', async ({ page }, ti) => {
  await mock(page, ti, { failPut: true });
  await open(page);
  await addLatte(page);
  await page.locator('#cartbar').click();
  await fillContact(page);
  await page.locator('#sendBtn').click();
  await expect(toast(page)).toHaveText('النت ضعيف، جرّب تاني');
  await expect(page.locator('#sendBtn')).toBeEnabled();
  await expect(page.locator('#cartN')).toHaveText('1');
});

test('Firebase down when the page opens: clear message, no crash', async ({ page }, ti) => {
  await mock(page, ti, { down: true });
  await open(page);
  await expect(page.locator('main')).toContainText('النت ضعيف');
  expect(ti.annotations.filter((a) => a.type === 'pageerror')).toEqual([]);
});

test('very slow network (4 s per request): menu still opens', async ({ page }, ti) => {
  await mock(page, ti, { delayMs: 4000 });
  await open(page);
  await expect(page.locator('#cafeName')).toHaveText(fx.pub.name, { timeout: 30_000 });
});

test('XSS: item names and staff-written reasons are shown as text', async ({ page }, ti) => {
  const evil = '<img src=x onerror="window.__xss=(window.__xss||[]).concat(1)">';
  await mock(page, ti, {
    trackc: { orders: { a: { n: 7, s: 'rejected', r: evil, at: '2026-01-01' } }, pays: { p1: { a: 5000, s: 'rejected', r: evil } } },
    trackt: { items: [{ q: 1, n: evil, m: evil, g: evil, p: 100 }], total: 100, paid: 0 },
  });
  await open(page);
  await expect(page.locator('.item').first()).toBeVisible();
  await page.locator('#ordersFab').click();
  await expect(page.locator('#ordersSheet')).toBeAttached();
  await page.waitForTimeout(500);
  const fired = await page.evaluate(() => window.__xss || []);
  expect(fired, 'HTML from the cafe side executed in the customer browser').toEqual([]);
});

test('huge menu: 60 categories × 25 items renders quickly', async ({ page }, ti) => {
  const cats = Array.from({ length: 60 }, (_, c) => ({ id: `c${c}`, n: `قسم ${c}` }));
  const items = cats.flatMap((c, ci) => Array.from({ length: 25 }, (_, i) => ({ id: `i${ci}_${i}`, c: c.id, n: `صنف ${ci}-${i}`, d: 'وصف طويل شوية للصنف ده عشان نشوف الرسم', p: 1000 + i })));
  await mock(page, ti, { menu: { v: 'big', cats, items, groups: [] } });
  const t0 = Date.now();
  await open(page);
  await expect(page.locator('.item')).toHaveCount(1500);
  const ms = Date.now() - t0;
  ti.annotations.push({ type: 'render', description: `1500 items in ${ms} ms` });
  expect(ms).toBeLessThan(5000);
});

test('corrupted phone storage does not break the page', async ({ page }, ti) => {
  await page.addInitScript((cafe) => {
    localStorage.setItem('ol_cart_' + cafe, '{broken');
    localStorage.setItem('ol_menu_' + cafe, '[1,2');
    localStorage.setItem('ol_lang', '"xx"');
  }, fx.cafe);
  await mock(page, ti);
  await open(page);
  await expect(page.locator('.item').first()).toBeVisible();
});

// ---------------------------------------------------------------- استهلاك Firebase (المرحلة 1)

const LOGO = 'iVBORw0KGgo' + 'A'.repeat(60_000); // لوجو حوالي 60 كيلو زي اللي بيتعمل من صورة حقيقية
const streams = (fb) => fb.reqs.filter((r) => r.stream).map((r) => r.path.split('/')[0]);
const setHidden = (page, hidden) => page.evaluate((h) => {
  Object.defineProperty(document, 'hidden', { configurable: true, get: () => h });
  document.dispatchEvent(new Event('visibilitychange'));
}, hidden);

test('logo: own node, downloaded once and kept on the phone (not every minute inside pub)', async ({ page }, ti) => {
  await page.clock.install();
  const fb = await mock(page, ti, { pub: { lv: 'logo-v1' }, logo: LOGO });
  await open(page);
  await expect(page.locator('#logo')).toBeVisible();
  await page.clock.runFor(10 * 60_000); // 10 دقايق والصفحة قدام العميل
  await page.reload();
  await expect(page.locator('#logo')).toBeVisible();
  const logoGets = fb.reqs.filter((r) => r.path.endsWith('/logo'));
  const pubGets = fb.reqs.filter((r) => r.path.endsWith('/pub'));
  ti.annotations.push({ type: 'usage', description: `pub × ${pubGets.length} = ${pubGets.reduce((s, r) => s + r.bytes, 0)} B, logo × ${logoGets.length} = ${logoGets.reduce((s, r) => s + r.bytes, 0)} B` });
  expect(logoGets).toHaveLength(1);
  expect(pubGets.length).toBeGreaterThanOrEqual(10);
  expect(Math.max(...pubGets.map((r) => r.bytes))).toBeLessThan(5_000);
});

test('old cashier version: logo inside pub still shows, no extra request', async ({ page }, ti) => {
  const fb = await mock(page, ti, { pub: { logo: 'iVBORw0KGgoAAAA' } });
  await open(page);
  await expect(page.locator('#logo')).toBeVisible();
  expect(fb.reqs.filter((r) => r.path.endsWith('/logo'))).toHaveLength(0);
});

test('one live connection per phone: the table bill comes inside the customer tracking (v2)', async ({ page }, ti) => {
  const fb = await mock(page, ti, {
    trackc: { v: 2, orders: { a: { n: 3, s: 'accepted', at: '2026-01-01' } }, tb: { k: fx.tableKey, n: 12, items: [{ q: 1, n: 'لاتيه كبير', p: 6000 }], total: 6000, paid: 0 } },
  });
  await open(page);
  await page.locator('#ordersFab').click();
  await expect(page.locator('#ordersSheet')).toBeAttached();
  await expect(page.locator('.sheet')).toContainText('لاتيه كبير');
  await page.locator('#closeOrders').click();
  await page.waitForTimeout(500);
  expect([...new Set(streams(fb))]).toEqual(['trackc']);
});

test('old cashier version (tracking without v2): still listens on the table bill', async ({ page }, ti) => {
  const fb = await mock(page, ti, {
    trackc: { orders: { a: { n: 3, s: 'accepted', at: '2026-01-01' } } },
    trackt: { n: 12, items: [{ q: 1, n: 'لاتيه قديم', p: 6000 }], total: 6000, paid: 0 },
  });
  await open(page);
  await expect.poll(() => streams(fb).includes('trackt')).toBe(true);
  await page.locator('#ordersFab').click();
  await expect(page.locator('.sheet')).toContainText('لاتيه قديم');
});

test('customer who has not ordered: table bill is read only while "my orders" is open', async ({ page }, ti) => {
  const fb = await mock(page, ti, { trackt: { n: 12, items: [{ q: 1, n: 'طلب الترابيزة', p: 6000 }], total: 6000, paid: 0 } });
  await open(page);
  await expect(page.locator('.item').first()).toBeVisible();
  await page.waitForTimeout(500);
  expect(streams(fb)).not.toContain('trackt');
  await page.locator('#ordersFab').click();
  await expect(page.locator('.sheet')).toContainText('طلب الترابيزة');
});

test('screen locked: no requests at all while hidden, live connection back when the customer returns', async ({ page }, ti) => {
  const fb = await mock(page, ti);
  await open(page);
  await expect(page.locator('.item').first()).toBeVisible();
  await page.waitForTimeout(500);
  await setHidden(page, true);
  const atHide = fb.reqs.length;
  await page.waitForTimeout(7_000); // أكتر من إعادة الاتصال (3 ث) والقراية الاحتياطية (6 ث)
  expect(fb.reqs.length, 'requests while the phone screen was off').toBe(atHide);
  await setHidden(page, false);
  await expect.poll(() => fb.reqs.slice(atHide).some((r) => r.stream)).toBe(true);
  await expect.poll(() => fb.reqs.slice(atHide).some((r) => r.path.endsWith('/pub'))).toBe(true);
});

test('real transfer screenshot (text on a plain background) uploads under 300 KB', async ({ page }, ti) => {
  const fb = await mock(page, ti);
  await open(page);
  await addLatte(page);
  await page.locator('#cartbar').click();
  await fillContact(page);
  await page.locator(`[data-pm="${wallet().id}"]`).click();
  // لقطة شاشة موبايل 1170×2532 فيها أرقام وكلام زي إيصال InstaPay
  const b64 = await page.evaluate(() => {
    const c = document.createElement('canvas'); c.width = 1170; c.height = 2532;
    const g = c.getContext('2d'); g.fillStyle = '#f4f1fb'; g.fillRect(0, 0, 1170, 2532);
    g.fillStyle = '#5b2a86'; g.fillRect(0, 0, 1170, 260);
    g.fillStyle = '#222'; g.font = '48px sans-serif';
    for (let i = 0; i < 30; i++) g.fillText(`Transfer ref 20261123-${1000 + i}   EGP ${(i * 37.5).toFixed(2)}`, 60, 360 + i * 70);
    return c.toDataURL('image/png').split(',')[1];
  });
  await page.locator('#proofIn').setInputFiles({ name: 'instapay.png', mimeType: 'image/png', buffer: Buffer.from(b64, 'base64') });
  await expect(page.locator('label.upl img')).toBeVisible({ timeout: 30_000 });
  await fillContact(page);
  await page.locator('#sendBtn').click();
  await expect(page.locator('.toast', { hasText: 'الطلب اتبعت' })).toBeVisible();
  const proof = fb.sent.find((s) => s.path.startsWith('proof/'));
  ti.annotations.push({ type: 'proof', description: `screenshot → uploaded ${(proof.body.d.length / 1024).toFixed(0)} KB` });
  expect(proof.body.d.length).toBeLessThanOrEqual(300_000);
});

// ---------------------------------------------------------------- محل على مشروع Firebase خاص بيه (المرحلة 2)

test('shop on its own Firebase project: the page talks to the database in ?d=, and refuses anything that is not Firebase', async ({ page }, ti) => {
  const SHOP = 'https://cafe-elnour-default-rtdb.europe-west1.firebasedatabase.app';
  const hits = { shop: 0, main: 0, evil: 0 };
  await page.route(`${SITE}/**`, (r) => r.fulfill({ status: 200, contentType: 'text/html; charset=utf-8', body: MENU_HTML }));
  const serve = (who) => async (r) => {
    hits[who]++;
    const p = new URL(r.request().url()).pathname.replace(/^\//, '').replace(/\.json$/, '').split('/');
    const data = p[2] === 'pub' ? fx.pub : p[2] === 'menu' ? fx.menu : p[2] === 'mv' ? fx.menu.v : p[2] === 'seen' ? Date.now() : p[2] === 'tables' ? fx.tables[p[3]] ?? null : null;
    if ((r.request().headers()['accept'] || '').includes('text/event-stream')) return r.fulfill({ status: 200, contentType: 'text/event-stream', body: `event: put\ndata: ${JSON.stringify({ path: '/', data })}\n\n` });
    return r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(data) });
  };
  await page.route(`${SHOP}/**`, serve('shop'));
  await page.route(`${DB}/**`, serve('main'));
  await page.route('https://evil.example.com/**', serve('evil'));

  await page.goto(`${SITE}/m/${fx.cafe}/${fx.tableKey}?d=cafe-elnour-default-rtdb.europe-west1.firebasedatabase.app`);
  await expect(page.locator('#cafeName')).toHaveText(fx.pub.name);
  expect(hits.shop).toBeGreaterThan(0);
  expect(hits.main).toBe(0);

  await page.goto(`${SITE}/m/${fx.cafe}/${fx.tableKey}?d=evil.example.com`);
  await expect(page.locator('#cafeName')).toHaveText(fx.pub.name);
  expect(hits.evil).toBe(0);
  expect(hits.main).toBeGreaterThan(0);
});
