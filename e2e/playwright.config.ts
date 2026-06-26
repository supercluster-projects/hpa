import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './',
  testMatch: '*.spec.ts',
  timeout: 30000,
  expect: {
    timeout: 10000,
  },
  retries: 1,
  reporter: 'list',
  use: {
    baseURL: process.env.PLAYWRIGHT_BASE_URL || 'http://localhost:8080',
    extraHTTPHeaders: {
      'Accept': 'text/plain',
    },
  },
});
