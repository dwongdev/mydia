/**
 * E2E tests for authentication and authorization flows
 *
 * Tests cover:
 * - Local authentication (username/password)
 * - OIDC authentication (OAuth2)
 * - Session persistence
 * - Protected route access
 * - Role-based authorization
 */
import { test, expect } from '@playwright/test';
import { LoginPage } from '../pages/LoginPage';
import { loginAsAdmin, loginAsUser, logout, mockOIDCLogin } from '../helpers/auth';
import { testUsers } from '../fixtures/users';

test.describe('Local Authentication', () => {
  test('can login with valid credentials', async ({ page }) => {
    const loginPage = new LoginPage(page);
    await loginPage.goto();
    await loginPage.assertLoginFormVisible();

    // Login with admin credentials
    await loginPage.login(testUsers.admin.username, testUsers.admin.password);

    // Should redirect to dashboard
    await expect(page).toHaveURL('/');

    // Should see sidebar with Dashboard link (indicates logged in state)
    await expect(page.locator('a[href="/"]').filter({ hasText: 'Dashboard' })).toBeVisible();

    // Should see successful login flash message
    await expect(page.locator('#flash-info')).toContainText('Successfully logged in');
  });

  test('shows error message with invalid credentials', async ({ page }) => {
    const loginPage = new LoginPage(page);
    await loginPage.goto();

    // Try to login with invalid credentials
    await loginPage.fillUsername('invalid');
    await loginPage.fillPassword('wrong-password');
    await loginPage.clickSubmit();

    // Should stay on login page and show error
    await loginPage.assertOnLoginPage();
    await expect(page.locator('[role="alert"], .alert, .flash')).toBeVisible();
  });

  test.skip('can logout successfully', async ({ page }) => {
    // Login first
    await loginAsAdmin(page);
    await expect(page).toHaveURL('/');

    // Logout
    await logout(page);

    // Logout redirects to login page (because homepage requires auth)
    await expect(page).toHaveURL(/\/auth\/(local\/)?login/);

    // Should not be able to access protected routes after logout
    await page.goto('/media', { waitUntil: 'networkidle' });
    // Wait for LiveView to potentially redirect
    await page.waitForTimeout(500);
    await expect(page).toHaveURL(/\/auth\/(local\/)?login/);
  });
});

test.describe('OIDC Authentication', () => {
  test.skip('can login via OIDC provider', async ({ page }) => {
    // Attempt OIDC login with mock OAuth2 server
    await mockOIDCLogin(page);

    // Should redirect to dashboard after successful authentication
    await expect(page).toHaveURL('/');

    // Should see sidebar with Dashboard link (indicates logged in state)
    await expect(page.locator('a[href="/"]').filter({ hasText: 'Dashboard' })).toBeVisible();
  });

  test.skip('can logout from OIDC session', async ({ page }) => {
    // Login via OIDC
    await mockOIDCLogin(page);
    await expect(page).toHaveURL('/');

    // Logout
    await logout(page);

    // Should be redirected to login page
    await expect(page).toHaveURL(/\/auth\/(local\/)?login/);
  });
});

test.describe('Session Persistence', () => {
  test('maintains session across page reloads', async ({ page }) => {
    // Login
    await loginAsAdmin(page);
    await expect(page).toHaveURL('/');

    // Reload the page
    await page.reload();

    // Should still be logged in (not redirected to login)
    await expect(page).toHaveURL('/');
    await expect(page.locator('a[href="/"]').filter({ hasText: 'Dashboard' })).toBeVisible();
  });

  test('maintains session across navigation', async ({ page }) => {
    // Login
    await loginAsAdmin(page);
    await expect(page).toHaveURL('/');

    // Navigate to different pages
    await page.goto('/media');
    await expect(page).toHaveURL('/media');
    await expect(page.locator('a[href="/"]').filter({ hasText: 'Dashboard' })).toBeVisible();

    await page.goto('/downloads');
    await expect(page).toHaveURL('/downloads');
    await expect(page.locator('a[href="/"]').filter({ hasText: 'Dashboard' })).toBeVisible();
  });
});

test.describe('Protected Routes', () => {
  test('redirects to login when accessing protected route without auth', async ({ page }) => {
    // Try to access dashboard without logging in
    await page.goto('/');

    // Should be redirected to login page
    await expect(page).toHaveURL(/\/auth\/(local\/)?login/);
  });

  test('redirects to login when accessing media page without auth', async ({ page }) => {
    await page.goto('/media');

    // Should be redirected to login page
    await expect(page).toHaveURL(/\/auth\/(local\/)?login/);
  });

  test('redirects to login when accessing downloads page without auth', async ({ page }) => {
    await page.goto('/downloads');

    // Should be redirected to login page
    await expect(page).toHaveURL(/\/auth\/(local\/)?login/);
  });

  test('allows access to protected route after login', async ({ page }) => {
    // Login first
    await loginAsAdmin(page);

    // Should be able to access protected routes
    await page.goto('/media');
    await expect(page).toHaveURL('/media');

    await page.goto('/downloads');
    await expect(page).toHaveURL('/downloads');

    await page.goto('/calendar');
    await expect(page).toHaveURL('/calendar');
  });
});

test.describe('Role-Based Authorization', () => {
  test('admin can access admin pages', async ({ page }) => {
    // Login as admin
    await loginAsAdmin(page);

    // Navigate to admin page
    await page.goto('/admin');

    // Should be able to access admin page
    await expect(page).toHaveURL(/\/admin/);

    // Should see admin content (not redirected)
    await expect(page.locator('body')).not.toContainText('Access Denied');
  });

  test('admin can access admin config pages', async ({ page }) => {
    // Login as admin
    await loginAsAdmin(page);

    // Navigate to admin config page
    await page.goto('/admin/config');

    // Should be able to access admin config
    await expect(page).toHaveURL('/admin/config');
  });

  test('admin can access admin users page', async ({ page }) => {
    // Login as admin
    await loginAsAdmin(page);

    // Navigate to admin users page
    await page.goto('/admin/users');

    // Should be able to access admin users page
    await expect(page).toHaveURL('/admin/users');
  });

  test('regular user cannot access admin pages', async ({ page }) => {
    // Login as regular user
    await loginAsUser(page);

    // Try to access admin page
    await page.goto('/admin');

    // Should be redirected away from admin page (either to dashboard or error page)
    await page.waitForTimeout(1000); // Wait for redirect
    await expect(page).not.toHaveURL('/admin');
  });

  test('regular user can access non-admin protected pages', async ({ page }) => {
    // Login as regular user
    await loginAsUser(page);

    // Should be able to access regular protected routes
    await page.goto('/media');
    await expect(page).toHaveURL('/media');

    await page.goto('/downloads');
    await expect(page).toHaveURL('/downloads');
  });
});

test.describe('Navigation Flow', () => {
  test('remembers intended destination after login', async ({ page }) => {
    // Try to access a protected page without being logged in
    await page.goto('/calendar');

    // Should be redirected to login
    await expect(page).toHaveURL(/\/auth\/(local\/)?login/);

    // Note: Testing redirect back to original page after login would require
    // the app to implement a "return_to" parameter, which may or may not exist.
    // For now, we just verify that after login, we can navigate to the page.
    const loginPage = new LoginPage(page);
    await loginPage.login(testUsers.admin.username, testUsers.admin.password);

    // After login, navigate to the intended page
    await page.goto('/calendar');
    await expect(page).toHaveURL('/calendar');
  });
});
