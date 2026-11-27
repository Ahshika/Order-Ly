// أبلكيشن المالك (Flutter web، firebase/public/owner) على الأيفون (WebKit) وأندرويد (Chromium)، وFirebase وهمي.
// التشغيل (من فولدر source بعد tool\build_owner_web.ps1):  cd test_web; npx playwright test --config owner/playwright.config.js
const { defineConfig, devices } = require('@playwright/test');
const path = require('path');

const out = process.env.WEB_OUT || path.join(__dirname, '..', '..', '..', 'test-results', 'owner-web');

module.exports = defineConfig({
  testDir: __dirname,
  testMatch: 'owner.spec.js',
  timeout: 120_000,
  expect: { timeout: 30_000 },
  workers: 1,
  outputDir: path.join(out, 'artifacts'),
  reporter: [['list'], ['html', { outputFolder: path.join(out, 'report'), open: 'never' }], ['json', { outputFile: path.join(out, 'playwright.json') }]],
  use: { locale: 'ar-EG', screenshot: 'only-on-failure', trace: 'retain-on-failure', acceptDownloads: true },
  projects: [
    { name: 'webkit-iphone', use: { ...devices['iPhone 14'] } },
    { name: 'chromium-android', use: { ...devices['Pixel 7'], isMobile: false, hasTouch: false } },
  ],
});
