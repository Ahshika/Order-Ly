// نسخة الويب للموظفين: بتفتح من سيرفر الكافيه، من غير نت خالص، والموظف يسجل دخول ويشوف الصالة.
const { test, expect } = require('@playwright/test');
const fs = require('fs');
const path = require('path');

const OUT = process.env.WEB_OUT;
const fx = JSON.parse(fs.readFileSync(path.join(OUT, 'staff-fixture.json'), 'utf8'));

/** أي طلب بره سيرفر الكافيه بيتقفل (زي كافيه من غير نت) وبيتسجل. */
async function noInternet(page) {
  const outside = [];
  await page.route('**/*', (r) => {
    const u = new URL(r.request().url());
    if (u.hostname === '127.0.0.1') return r.continue();
    outside.push(r.request().url());
    return r.abort('internetdisconnected');
  });
  return outside;
}

/** Flutter بيرسم على canvas: الصفحة بتتفتح بـ ?a11y=1 عشان شجرة الـ accessibility تبقى شغالة ونلاقي الزراير بأساميها. */
async function semantics(page) {
  await page.waitForSelector('flt-semantics[role], flt-semantics input', { state: 'attached', timeout: 90_000 });
}

/** Flutter بيعمل خانة الكتابة الحقيقية بعد اللمسة: بنستنى لحد ما تبقى جاهزة قبل ما نكتب (زي الإيد بالظبط). */
async function typeInto(page, field, text) {
  await field.click();
  await page.waitForFunction(() => ['INPUT', 'TEXTAREA'].includes(document.activeElement && document.activeElement.tagName));
  await page.keyboard.type(text, { delay: 30 });
}

test('opens from the cashier PC with no internet, waiter logs in and sees the floor', async ({ page }, ti) => {
  const outside = await noInternet(page);
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  const t0 = Date.now();
  await page.goto(fx.base + '/?a11y=1');
  await semantics(page);
  const user = page.getByRole('textbox', { name: 'اسم المستخدم' });
  await expect(user).toBeVisible({ timeout: 60_000 });
  ti.annotations.push({ type: 'load', description: `login screen after ${Date.now() - t0} ms` });
  await typeInto(page, user, fx.user);
  await typeInto(page, page.getByRole('textbox', { name: 'كلمة السر' }), fx.pass);
  await page.getByRole('button', { name: 'دخول' }).click();
  // الصالة نفسها بالترابيزات الـ 4 اللي على السيرفر (مش بس اسم القسم). Flutter بيجمع كلام الكارت في label واحد
  await expect
    .poll(() => page.evaluate(() => {
      const h = document.querySelector('flt-semantics-host');
      const all = h.innerText + ' ' + [...h.querySelectorAll('[aria-label]')].map((e) => e.getAttribute('aria-label')).join(' ');
      return (all.match(/فاضية/g) || []).length;
    }), { timeout: 60_000 })
    .toBe(4);
  await page.screenshot({ path: path.join(OUT, `staff-floor-${ti.project.name}.png`) });
  ti.annotations.push({ type: 'outside', description: outside.length ? outside.join(' | ') : 'none' });
  expect(errors, errors.join('\n')).toEqual([]);
  // البرنامج نفسه كله من سيرفر الكافيه. (خطوط احتياطية لحرف مش موجود ممكن تتطلب من Google وتفشل من غير ما تأثر)
  expect(outside.filter((u) => !/fonts\.gstatic\.com/.test(u))).toEqual([]);
});

test('home-screen tags for the iPhone are in place', async ({ page }) => {
  await noInternet(page);
  await page.goto(fx.base + '/');
  await expect(page.locator('meta[name="apple-mobile-web-app-capable"]')).toHaveAttribute('content', 'yes');
  await expect(page.locator('link[rel="apple-touch-icon"]')).toHaveAttribute('href', 'icons/Icon-180.png');
  const manifest = await (await page.request.get(fx.base + '/manifest.json')).json();
  expect(manifest.name).toBe('Order Ly');
  expect(manifest.display).toBe('standalone');
  expect((await page.request.get(fx.base + '/icons/Icon-180.png')).status()).toBe(200);
});
