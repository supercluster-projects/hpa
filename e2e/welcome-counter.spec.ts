import { test, expect } from '@playwright/test';

/**
 * Playwright e2e tests for HPA welcome and counter workloads.
 *
 * These tests verify:
 * - /api/welcome returns "Welcome (N)" with incrementing count
 * - Content-Type header is text/plain
 * - /admin loads the Headlamp dashboard
 *
 * Run with: PLAYWRIGHT_BASE_URL=http://<envoy-ip> npx playwright test
 */

test.describe('/api/welcome endpoint', () => {
  test('returns Welcome (N) format with status 200 and text/plain content type', async ({ request }) => {
    const response = await request.get('/api/welcome');

    expect(response.status()).toBe(200);

    const contentType = response.headers()['content-type'] || response.headers()['Content-Type'] || '';
    expect(contentType).toContain('text/plain');

    const body = await response.text();
    expect(body).toMatch(/^Welcome \(\d+\)$/);
  });

  test('returns incrementing count across 5 sequential calls', async ({ request }) => {
    const counts: number[] = [];

    for (let i = 0; i < 5; i++) {
      const response = await request.get('/api/welcome');
      expect(response.status()).toBe(200);

      const body = await response.text();
      const match = body.match(/^Welcome \((\d+)\)$/);
      expect(match).not.toBeNull();
      const count = parseInt(match![1], 10);
      counts.push(count);
    }

    // Verify each subsequent count is exactly previous + 1
    for (let i = 1; i < counts.length; i++) {
      expect(counts[i]).toBe(counts[i - 1] + 1);
    }
  });

  test('Content-Type header is text/plain', async ({ request }) => {
    const response = await request.get('/api/welcome');
    expect(response.status()).toBe(200);

    const contentType = response.headers()['content-type'] || '';
    expect(contentType).toContain('text/plain');
  });
});

test.describe('/admin endpoint', () => {
  test('loads Headlamp dashboard with k8s content visible', async ({ page }) => {
    // Navigate to /admin and verify Headlamp loads
    await page.goto('/admin', { waitUntil: 'networkidle' });

    // Headlamp typically shows its title or a cluster-related heading
    const pageTitle = await page.title();
    expect(
      pageTitle.toLowerCase().includes('headlamp') ||
      pageTitle.toLowerCase().includes('kubernetes') ||
      pageTitle.toLowerCase().includes('dashboard')
    ).toBeTruthy();

    // Verify that at least one visible heading or navigation element exists
    // Headlamp renders several nav items; any visible heading confirms the app loaded
    const headings = page.locator('h1, h2, h3, nav, [role="navigation"]');
    await expect(headings.first()).toBeVisible({ timeout: 15000 });
  });
});
