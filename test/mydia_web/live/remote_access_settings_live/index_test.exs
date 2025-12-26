defmodule MydiaWeb.RemoteAccessSettingsLive.IndexTest do
  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Mydia.RemoteAccess

  setup %{conn: conn} do
    admin = create_admin_user()
    conn = log_in_user(conn, admin)
    %{conn: conn, user: admin}
  end

  describe "mount" do
    test "renders the page with no configuration", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings/remote-access")

      assert has_element?(view, "h1", "Remote Access Settings")
      assert has_element?(view, "input[type='checkbox'].toggle")
    end

    test "renders the page with existing configuration", %{conn: conn} do
      # Initialize keypair
      {:ok, _config} = RemoteAccess.initialize_keypair()

      {:ok, view, _html} = live(conn, ~p"/admin/settings/remote-access")

      assert has_element?(view, "h1", "Remote Access Settings")
      assert has_element?(view, "h2", "Instance Information")
    end
  end

  describe "toggle remote access" do
    test "enables remote access and initializes keypair", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings/remote-access")

      # Enable remote access
      view
      |> element("input[type='checkbox'].toggle")
      |> render_click(%{"enabled" => "true"})

      # Should show success message
      assert render(view) =~ "Remote access enabled"

      # Should now show instance information
      assert has_element?(view, "h2", "Instance Information")

      # Verify config was created
      config = RemoteAccess.get_config()
      assert config
      assert config.enabled
      assert config.instance_id
      assert config.static_public_key
    end

    test "disables remote access", %{conn: conn} do
      # Initialize and enable first
      {:ok, _config} = RemoteAccess.initialize_keypair()
      {:ok, _config} = RemoteAccess.toggle_remote_access(true)

      {:ok, view, _html} = live(conn, ~p"/admin/settings/remote-access")

      # Disable remote access
      view
      |> element("input[type='checkbox'].toggle")
      |> render_click(%{"enabled" => "false"})

      # Should show success message
      assert render(view) =~ "Remote access disabled"

      # Verify config was disabled
      updated_config = RemoteAccess.get_config()
      refute updated_config.enabled
    end
  end

  describe "generate claim code" do
    setup %{conn: conn} do
      # Initialize and enable remote access
      {:ok, _config} = RemoteAccess.initialize_keypair()
      {:ok, _config} = RemoteAccess.toggle_remote_access(true)

      {:ok, view, _html} = live(conn, ~p"/admin/settings/remote-access")

      %{view: view}
    end

    test "generates a pairing code", %{view: view} do
      # Click generate button
      view
      |> element("button", "Generate Pairing Code")
      |> render_click()

      # Should show the code
      html = render(view)
      assert html =~ "Your Pairing Code"
      assert html =~ "Expires in:"

      # Should have a copy button
      assert has_element?(view, "button[title='Copy code']")
    end

    test "displays countdown timer", %{view: view} do
      # Generate code
      view
      |> element("button", "Generate Pairing Code")
      |> render_click()

      # Should show countdown
      html = render(view)
      # Format: M:SS
      assert html =~ ~r/\d+:\d{2}/
    end

    test "allows generating a new code", %{view: view} do
      # Generate first code
      view
      |> element("button", "Generate Pairing Code")
      |> render_click()

      html1 = render(view)

      # Generate new code
      view
      |> element("button", "Generate New Code")
      |> render_click()

      html2 = render(view)

      # Both should have codes (they might be the same or different)
      assert html1 =~ "Your Pairing Code"
      assert html2 =~ "Your Pairing Code"
    end
  end

  describe "instance information" do
    setup %{conn: conn} do
      # Initialize remote access
      {:ok, config} = RemoteAccess.initialize_keypair()

      {:ok, view, _html} = live(conn, ~p"/admin/settings/remote-access")

      %{view: view, config: config}
    end

    test "displays instance ID", %{view: view, config: config} do
      assert has_element?(view, "input[value='#{config.instance_id}']")
    end

    test "displays public key", %{view: view, config: config} do
      public_key_b64 = Base.encode64(config.static_public_key)
      assert has_element?(view, "input[value='#{public_key_b64}']")
    end

    test "displays relay URL", %{view: view} do
      assert has_element?(view, "input[value*='relay.mydia.app']")
    end

    test "displays QR code", %{view: view} do
      html = render(view)
      # QR code is rendered as SVG
      assert html =~ "<svg"
    end

    test "has copy buttons", %{view: view} do
      assert has_element?(view, "button[title='Copy public key']")
    end
  end

  describe "copy actions" do
    setup %{conn: conn} do
      # Initialize remote access
      {:ok, _config} = RemoteAccess.initialize_keypair()
      {:ok, _config} = RemoteAccess.toggle_remote_access(true)

      {:ok, view, _html} = live(conn, ~p"/admin/settings/remote-access")

      %{view: view}
    end

    test "copy public key shows flash", %{view: view} do
      view
      |> element("button[title='Copy public key']")
      |> render_click()

      assert render(view) =~ "Public key copied to clipboard"
    end

    test "copy claim code shows flash", %{view: view} do
      # Generate code first
      view
      |> element("button", "Generate Pairing Code")
      |> render_click()

      # Copy code
      view
      |> element("button[title='Copy code']")
      |> render_click()

      assert render(view) =~ "Code copied to clipboard"
    end
  end

  describe "authorization" do
    test "requires admin role" do
      # Create a regular user (not admin)
      user = create_test_user(%{role: "user"})
      conn = Phoenix.ConnTest.build_conn()
      conn = log_in_user(conn, user)

      # Should redirect/error
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/settings/remote-access")
    end
  end
end
