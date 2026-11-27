// نسخة الويب للموظفين (Flutter web) على محرك الأيفون (WebKit) وأندرويد (Chromium). التشغيل: run.ps1.
const { defineConfig, devices } = require('@playwright/test');
const path = require('path');

const out = process.env.WEB_OUT || path.join(__dirname, '..', '..', '..', 'test-results', 'staff-web');

module.exports = defineConfig({
  testDir: __dirname,
  testMatch: 'staff.spec.js',
  timeout: 120_000,
  expect: { timeout: 30_000 },
  workers: 1,
  outputDir: path.join(out, 'artifacts'),
  reporter: [['list'], ['html', { outputFolder: path.join(out, 'report'), open: 'never' }], ['json', { outputFile: path.join(out, 'playwright.json') }]],
  use: { locale: 'ar-EG', screenshot: 'only-on-failure', trace: 'retain-on-failure' },
  projects: [
    { name: 'webkit-iphone', use: { ...devices['iPhone 14'] } },
    // شاشة وموبايل أندرويد. isMobile مقفول بس عشان الاختبار يقدر يشغّل شجرة الـ accessibility بتاعة Flutter بضغطة
    { name: 'chromium-android', use: { ...devices['Pixel 7'], isMobile: false, hasTouch: false } },
  ],
});
