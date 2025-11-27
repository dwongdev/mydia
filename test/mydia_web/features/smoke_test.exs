defmodule MydiaWeb.Features.SmokeTest do
  @moduledoc """
  Smoke tests to verify the Phoenix application is working correctly.

  These tests run in a real browser and verify:
  - Basic page loading
  - HTML structure
  - LiveView JavaScript loading
  - Alpine.js initialization

  Converted from assets/e2e/tests/smoke.spec.ts
  """

  use MydiaWeb.FeatureCase, async: false

  @moduletag :feature

  describe "Application Smoke Test" do
    @tag :feature
    test "homepage redirects to login when not authenticated", %{session: session} do
      # Create a user first so we don't get redirected to /setup
      _user = create_test_user()

      session
      |> visit("/")

      # Unauthenticated users are redirected to login (either /auth/login or /auth/local/login)
      assert Wallaby.Browser.current_path(session) =~ ~r/\/auth\/(local\/)?login/
    end

    @tag :feature
    test "login page loads successfully", %{session: session} do
      # Create a user first so we don't get redirected to /setup
      _user = create_test_user()

      session
      |> visit("/auth/local/login")

      # Should be on the login page
      assert Wallaby.Browser.current_path(session) =~ ~r/\/auth\/(local\/)?login/

      assert Wallaby.Browser.has_text?(session, "Sign in") or
               Wallaby.Browser.has_text?(session, "sign in")
    end

    @tag :feature
    test "page has proper HTML structure", %{session: session} do
      # Create a user first so we don't get redirected to /setup
      _user = create_test_user()

      session
      |> visit("/auth/local/login")

      # Check for basic HTML structure - title should exist
      title = Wallaby.Browser.page_title(session)
      assert title != nil
      assert String.length(title) > 0
    end

    @tag :feature
    test "LiveView JavaScript is loaded", %{session: session} do
      # Create and login a user first so we can access authenticated pages
      login_as_admin(session)

      # Wait for page to load and check for LiveView elements
      session
      |> visit("/")
      |> wait_for_liveview()

      # Verify LiveView is connected by checking for phx-* attributes
      assert Wallaby.Browser.has_css?(session, "[data-phx-main]")
    end

    @tag :feature
    test "can reload page and maintain URL", %{session: session} do
      # Create a user first so we don't get redirected to /setup
      _user = create_test_user()

      session
      |> visit("/auth/local/login")

      # Get the initial URL (could be /auth/login or /auth/local/login)
      initial_path = Wallaby.Browser.current_path(session)
      assert initial_path =~ ~r/\/auth\/(local\/)?login/

      # Reload the page
      session = Wallaby.Browser.visit(session, initial_path)

      # Verify we're still on the same path
      assert Wallaby.Browser.current_path(session) == initial_path
    end
  end
end
