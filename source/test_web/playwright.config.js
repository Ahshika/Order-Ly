// Playwright لمنيو العميل (firebase/public/menu.html) على 3 محركات متصفحات بمقاس موبايل.
// Firebase وهمي بالكامل (page.route)، فمفيش أي طلب بيخرج للنت. التشغيل: run.ps1 في نفس الفولدر.
const { defineConfig, devices } = require('@playwright/test');
const path = require('path');

const out = process.env.WEB_OUT || path.join(__dirname, '..', '..', 'test-results', 'web');

// على بعض نسخ ويندوز (Insider) Firefox مابيشتغلش من مكانه الأصلي (SideBySide: mozglue)، ونفس النسخة شغالة من مكان تاني.
// FIREFOX_PATH = مسار firefox.exe (نفس البناء بتاع Playwright) لو محتاجينه.
const firefoxPath = process.env.FIREFOX_PATH;

module.exports = defineConfig({
  testDir: __dirname,
  testMatch: '*.spec.js',
  timeout: 60_000,
  expect: { timeout: 10_000 },
  fullyParallel: true,
  workers: 3,
  outputDir: path.join(out, 'artifacts'),
  reporter: [['list'], ['html', { outputFolder: path.join(out, 'report'), open: 'never' }], ['json', { outputFile: path.join(out, 'playwright.json') }]],
  use: { locale: 'ar-EG', screenshot: 'only-on-failure', trace: 'retain-on-failure' },
  projects: [
    { name: 'chromium-android', use: { ...devices['Pixel 7'] } },
    { name: 'webkit-iphone', use: { ...devices['iPhone 14'] } },
    {
      name: 'firefox-phone',
      use: { browserName: 'firefox', viewport: { width: 390, height: 844 }, ...(firefoxPath ? { launchOptions: { executablePath: firefoxPath } } : {}) },
    },
  ],
});
