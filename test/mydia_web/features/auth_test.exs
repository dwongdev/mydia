defmodule MydiaWeb.Features.AuthTest do
  @moduledoc """
  Feature tests for authentication and authorization flows.

  Tests cover:
  - Local authentication (username/password)
  - Session persistence
  - Protected route access
  - Role-based authorization

  Converted from assets/e2e/tests/auth.spec.ts
  """

  use MydiaWeb.FeatureCase, async: false

  @moduletag :feature

  describe "Local Authentication" do
    @tag :feature
    test "can login with valid credentials", %{session: session} do
      user = create_admin_user()

      session
      |> visit("/auth/local/login")
      |> fill_in(Query.text_field("user[username]"), with: user.username)
      |> fill_in(Query.text_field("user[password]"), with: "password123")
      |> click(Query.button("Log In"))

      # Wait for dashboard to load after login redirect
      session
      |> wait_for_liveview()
      |> assert_path("/")
      |> assert_has_text("Dashboard")
    end

    @tag :feature
    test "shows error message with invalid credentials", %{session: session} do
      # Create a user so we don't get redirected to /setup
      _user = create_test_user()

      session
      |> visit("/auth/local/login")
      |> fill_in(Query.text_field("user[username]"), with: "invalid")
      |> fill_in(Query.text_field("user[password]"), with: "wrong-password")
      |> click(Query.button("Log In"))

      # Should stay on login page and show error
      assert Wallaby.Browser.current_path(session) =~ ~r/\/auth\/(local\/)?login/
      assert Wallaby.Browser.has_css?(session, "[role='alert'], .alert")
    end

    @tag :feature
    test "can logout successfully", %{session: session} do
      # Login first
      login_as_admin(session)

      # Wait for dashboard to load
      session
      |> wait_for_liveview()
      |> assert_path("/")

      # Logout
      session
      |> visit("/auth/logout")

      # Should redirect to login page
      assert Wallaby.Browser.current_path(session) =~ ~r/\/auth\/(local\/)?login/
    end
  end

  describe "Session Persistence" do
    @tag :feature
    test "maintains session across page reloads", %{session: session} do
      # Login
      login_as_admin(session)

      # Wait for dashboard to load after login redirect
      session
      |> wait_for_liveview()
      |> assert_path("/")

      # Reload the page
      session = Wallaby.Browser.visit(session, "/")
      session |> wait_for_liveview()

      # Should still be logged in (not redirected to login)
      assert_path(session, "/")
      assert Wallaby.Browser.has_text?(session, "Dashboard")
    end

    @tag :feature
    test "maintains session across navigation", %{session: session} do
      # Login
      login_as_admin(session)

      # Wait for dashboard to load after login redirect
      session
      |> wait_for_liveview()
      |> assert_path("/")

      # Navigate to different pages
      session
      |> visit("/media")
      |> wait_for_liveview()
      |> assert_path("/media")

      assert Wallaby.Browser.has_text?(session, "Dashboard")

      session
      |> visit("/downloads")
      |> wait_for_liveview()
      |> assert_path("/downloads")

      assert Wallaby.Browser.has_text?(session, "Dashboard")
    end
  end

  describe "Protected Routes" do
    @tag :feature
    test "redirects to login when accessing protected route without auth", %{session: session} do
      # Create a user so we don't get redirected to /setup
      _user = create_test_user()

      # Try to access dashboard without logging in
      session
      |> visit("/")

      # Should be redirected to login page
      assert Wallaby.Browser.current_path(session) =~ ~r/\/auth\/(local\/)?login/
    end

    @tag :feature
    test "redirects to login when accessing media page without auth", %{session: session} do
      # Create a user so we don't get redirected to /setup
      _user = create_test_user()

      session
      |> visit("/media")

      # Should be redirected to login page
      assert Wallaby.Browser.current_path(session) =~ ~r/\/auth\/(local\/)?login/
    end

    @tag :feature
    test "redirects to login when accessing downloads page without auth", %{session: session} do
      # Create a user so we don't get redirected to /setup
      _user = create_test_user()

      session
      |> visit("/downloads")

      # Should be redirected to login page
      assert Wallaby.Browser.current_path(session) =~ ~r/\/auth\/(local\/)?login/
    end

    @tag :feature
    test "allows access to protected route after login", %{session: session} do
      # Login first
      login_as_admin(session)

      # Wait for dashboard to load after login redirect
      session |> wait_for_liveview()

      # Should be able to access protected routes
      session
      |> visit("/media")
      |> wait_for_liveview()
      |> assert_path("/media")

      session
      |> visit("/downloads")
      |> wait_for_liveview()
      |> assert_path("/downloads")

      session
      |> visit("/calendar")
      |> wait_for_liveview()
      |> assert_path("/calendar")
    end
  end

  describe "Role-Based Authorization" do
    @tag :feature
    test "admin can access admin pages", %{session: session} do
      # Login as admin
      login_as_admin(session)

      # Wait for dashboard to load after login redirect
      session |> wait_for_liveview()

      # Navigate to admin page
      session
      |> visit("/admin")
      |> wait_for_liveview()

      # Should be able to access admin page (URL should contain /admin)
      assert Wallaby.Browser.current_path(session) =~ ~r/\/admin/

      # Should see admin content (not access denied)
      refute Wallaby.Browser.has_text?(session, "Access Denied")
    end

    @tag :feature
    test "admin can access admin config pages", %{session: session} do
      # Login as admin
      login_as_admin(session)

      # Wait for dashboard to load after login redirect
      session
      |> wait_for_liveview()
      |> assert_path("/")

      # Navigate to admin config page
      session
      |> visit("/admin/config")
      |> wait_for_liveview()
      |> assert_path("/admin/config")
    end

    @tag :feature
    test "admin can access admin users page", %{session: session} do
      # Login as admin
      login_as_admin(session)

      # Wait for dashboard to load after login redirect
      session |> wait_for_liveview()

      # Navigate to admin users page
      session
      |> visit("/admin/users")
      |> wait_for_liveview()
      |> assert_path("/admin/users")
    end

    @tag :feature
    test "regular user cannot access admin pages", %{session: session} do
      # Login as regular user
      login_as_user(session)

      # Wait for dashboard to load after login redirect
      session |> wait_for_liveview()

      # Try to access admin page
      session
      |> visit("/admin")
      |> wait_for_liveview()

      # Should be redirected away from admin page
      refute Wallaby.Browser.current_path(session) == "/admin"
    end

    @tag :feature
    test "regular user can access non-admin protected pages", %{session: session} do
      # Login as regular user
      login_as_user(session)

      # Wait for dashboard to load after login redirect
      session |> wait_for_liveview()

      # Should be able to access regular protected routes
      session
      |> visit("/media")
      |> wait_for_liveview()
      |> assert_path("/media")

      session
      |> visit("/downloads")
      |> wait_for_liveview()
      |> assert_path("/downloads")
    end
  end

  describe "Navigation Flow" do
    @tag :feature
    test "can access intended page after login", %{session: session} do
      # Create a user so we don't get redirected to /setup
      _existing_user = create_test_user()

      # Try to access a protected page without being logged in
      session
      |> visit("/calendar")

      # Should be redirected to login
      assert Wallaby.Browser.current_path(session) =~ ~r/\/auth\/(local\/)?login/

      # Create and login with admin user
      user = create_admin_user()

      session
      |> visit("/auth/local/login")
      |> fill_in(Query.text_field("user[username]"), with: user.username)
      |> fill_in(Query.text_field("user[password]"), with: "password123")
      |> click(Query.button("Log In"))

      # Wait for dashboard to load after login redirect
      session |> wait_for_liveview()

      # After login, navigate to the intended page
      session
      |> visit("/calendar")
      |> wait_for_liveview()
      |> assert_path("/calendar")
    end
  end

  describe "Auto-Promotion" do
    @tag :feature
    test "local auth users maintain their assigned roles", %{session: session} do
      admin_user = create_admin_user()
      regular_user = create_test_user()

      # Login as admin user
      session
      |> visit("/auth/local/login")
      |> fill_in(Query.text_field("user[username]"), with: admin_user.username)
      |> fill_in(Query.text_field("user[password]"), with: "password123")
      |> click(Query.button("Log In"))

      # Wait for dashboard to load after login redirect
      session |> wait_for_liveview()
      assert_path(session, "/")

      # Verify admin can access admin pages
      session
      |> visit("/admin")
      |> wait_for_liveview()

      assert Wallaby.Browser.current_path(session) =~ ~r/\/admin/

      # Logout
      session
      |> visit("/auth/logout")

      assert Wallaby.Browser.current_path(session) =~ ~r/\/auth\/(local\/)?login/

      # Login as regular user
      session
      |> visit("/auth/local/login")
      |> fill_in(Query.text_field("user[username]"), with: regular_user.username)
      |> fill_in(Query.text_field("user[password]"), with: "password123")
      |> click(Query.button("Log In"))

      # Wait for dashboard to load after login redirect
      session |> wait_for_liveview()
      assert_path(session, "/")

      # Verify regular user cannot access admin pages
      session
      |> visit("/admin")
      |> wait_for_liveview()

      refute Wallaby.Browser.current_path(session) == "/admin"
    end
  end
end
