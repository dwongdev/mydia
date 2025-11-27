defmodule MydiaWeb.FeatureCase do
  @moduledoc """
  This module defines the test case for browser-based feature tests using Wallaby.

  Feature tests run in a real browser (headless Chrome by default) and can test
  JavaScript interactions, LiveView updates, and real-time features.

  ## Why Wallaby over Playwright?

  - **Native Elixir integration**: Tests are written in Elixir and run with ExUnit
  - **Ecto sandbox support**: Each test runs in a database transaction, automatically rolled back
  - **Concurrent execution**: Tests can run in parallel without data conflicts
  - **No Node.js dependency**: Eliminates the need for a separate Node.js E2E test infrastructure
  - **Consistent patterns**: Same testing patterns as the rest of the codebase

  ## Usage

      defmodule MydiaWeb.AuthFeatureTest do
        use MydiaWeb.FeatureCase, async: false

        @moduletag :feature  # Mark all tests in this module as feature tests

        @tag :feature
        test "user can login", %{session: session} do
          session
          |> visit("/auth/local/login")
          |> fill_in(Query.text_field("user[username]"), with: "admin")
          |> fill_in(Query.text_field("user[password]"), with: "password")
          |> click(Query.button("Sign in"))
          |> assert_path("/")
        end
      end

  ## Prerequisites

  Feature tests require chromedriver to be installed. The Dockerfile.dev includes
  chromium and chromium-driver by default. After updating the Dockerfile, rebuild
  your container:

      ./dev down
      docker compose build --no-cache app
      ./dev up -d

  For local development outside Docker:

      # macOS
      brew install chromedriver

      # Ubuntu/Debian
      sudo apt-get install chromium-chromedriver

      # Or specify a custom path in test.exs
      config :wallaby, :chromedriver, path: "/path/to/chromedriver"

  ## Running Feature Tests

  Feature tests are excluded by default to avoid requiring chromedriver for
  regular test runs. To run them:

      # Run all feature tests
      ./dev mix test --only feature

      # Run a specific feature test file
      ./dev mix test test/mydia_web/features/auth_test.exs --include feature

      # Run with visible browser (for debugging)
      WALLABY_HEADLESS=false ./dev mix test --only feature

      # Run all tests including feature tests
      ./dev mix test --include feature

  ## Helper Functions

  This module provides several helper functions:

  - `login(session, username, password)` - Login with credentials
  - `login_as_admin(session)` - Create an admin user and login
  - `login_as_user(session)` - Create a regular user and login
  - `assert_path(session, path)` - Assert current URL path
  - `assert_has_text(session, text)` - Assert page contains text
  - `wait_for_liveview(session)` - Wait for LiveView to connect

  ## Wallaby DSL Reference

  The `use Wallaby.DSL` brings in the following commonly used functions:

  - `visit(session, path)` - Navigate to a URL
  - `fill_in(session, query, with: value)` - Fill in a form field
  - `click(session, query)` - Click an element
  - `Query.text_field(name)` - Find an input by name
  - `Query.button(text)` - Find a button by text
  - `Query.css(selector)` - Find by CSS selector
  - `Query.link(text)` - Find a link by text

  See Wallaby documentation for more: https://hexdocs.pm/wallaby

  ## Notes

  - Feature tests use the Ecto sandbox with allowances for browser connections
  - The test server runs on port 4002 (configured in test.exs)
  - Screenshots are automatically captured on test failure to tmp/wallaby_screenshots
  - Set `async: false` since SQLite doesn't handle concurrent writes well
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use Wallaby.DSL

      import MydiaWeb.FeatureCase
      import Mydia.Factory

      alias MydiaWeb.Router.Helpers, as: Routes

      @endpoint MydiaWeb.Endpoint
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Mydia.Repo, shared: not tags[:async])

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)

    metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(Mydia.Repo, pid)
    {:ok, session} = Wallaby.start_session(metadata: metadata)

    on_exit(fn ->
      Wallaby.end_session(session)
    end)

    {:ok, session: session}
  end

  @doc """
  Visits the login page and fills in the login form with the given credentials.
  """
  def login(session, username, password) do
    session
    |> Wallaby.Browser.visit("/auth/local/login")
    |> Wallaby.Browser.fill_in(Wallaby.Query.text_field("user[username]"), with: username)
    |> Wallaby.Browser.fill_in(Wallaby.Query.text_field("user[password]"), with: password)
    |> Wallaby.Browser.click(Wallaby.Query.button("Log In"))
  end

  @doc """
  Creates a test user and logs them in via the browser.
  Returns the session with the user logged in.
  """
  def login_as_admin(session) do
    user = create_admin_user()
    login(session, user.username, "password123")
  end

  @doc """
  Creates a regular test user and logs them in via the browser.
  Returns the session with the user logged in.
  """
  def login_as_user(session) do
    user = create_test_user()
    login(session, user.username, "password123")
  end

  @doc """
  Creates an admin user for feature tests.
  """
  def create_admin_user(attrs \\ %{}) do
    default_attrs = %{
      email: "admin-#{System.unique_integer([:positive])}@example.com",
      username: "admin#{System.unique_integer([:positive])}",
      password: "password123",
      role: "admin"
    }

    {:ok, user} =
      default_attrs
      |> Map.merge(attrs)
      |> Mydia.Accounts.create_user()

    user
  end

  @doc """
  Creates a regular user for feature tests.
  """
  def create_test_user(attrs \\ %{}) do
    default_attrs = %{
      email: "test-#{System.unique_integer([:positive])}@example.com",
      username: "testuser#{System.unique_integer([:positive])}",
      password: "password123",
      role: "user"
    }

    {:ok, user} =
      default_attrs
      |> Map.merge(attrs)
      |> Mydia.Accounts.create_user()

    user
  end

  @doc """
  Asserts that the current path matches the expected path.
  """
  def assert_path(session, expected_path) do
    assert Wallaby.Browser.current_path(session) == expected_path
    session
  end

  @doc """
  Asserts that the page contains the given text.
  """
  def assert_has_text(session, text) do
    assert Wallaby.Browser.has_text?(session, text)
    session
  end

  @doc """
  Waits for LiveView to connect and be ready.
  Useful after navigation or form submissions.
  """
  def wait_for_liveview(session) do
    # Wait for phx-connected attribute which indicates LiveView is fully mounted
    session
    |> Wallaby.Browser.find(Wallaby.Query.css("[data-phx-main]", []))
    |> then(fn _ -> session end)
  end
end
