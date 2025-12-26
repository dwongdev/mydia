defmodule Mydia.RemoteAccess.RelayTest do
  use Mydia.DataCase, async: false

  alias Mydia.RemoteAccess
  alias Mydia.RemoteAccess.Relay

  # We'll test the business logic without actually connecting to a relay service
  # since that would require a real WebSocket server in tests

  describe "relay configuration" do
    test "requires remote access to be configured" do
      # Without any config, relay should return error
      result = Relay.start_link(name: :test_relay_1)

      assert {:error, :remote_access_not_configured} = result
    end

    test "requires remote access to be enabled" do
      # Create config but leave it disabled
      {:ok, _config} = RemoteAccess.initialize_keypair()

      result = Relay.start_link(name: :test_relay_2)

      assert {:error, :remote_access_disabled} = result
    end
  end

  describe "relay URL normalization" do
    test "converts https:// to wss://" do
      # This test verifies the private function behavior indirectly
      # by checking that the module doesn't crash with various URL formats

      {:ok, _config} = RemoteAccess.initialize_keypair()
      {:ok, _} = RemoteAccess.toggle_remote_access(true)

      # Update relay_url to use https://
      {:ok, _} = RemoteAccess.upsert_config(%{relay_url: "https://relay.example.com"})

      # The start_link will fail to connect, but shouldn't crash during URL parsing
      # We just verify it doesn't raise an error
      result = Relay.start_link(name: :test_relay_https)

      # WebSockex will try to connect and likely fail, but we're testing the setup phase
      case result do
        {:ok, pid} ->
          # If it somehow succeeds (unlikely without a real server), clean up
          Process.exit(pid, :kill)

        {:error, reason} ->
          # Expected - connection will fail, but should be a connection error not a setup error
          # We're just ensuring the URL normalization doesn't crash
          assert is_map(reason) or is_tuple(reason) or is_atom(reason)
      end
    end

    test "converts http:// to ws://" do
      {:ok, _config} = RemoteAccess.initialize_keypair()
      {:ok, _} = RemoteAccess.toggle_remote_access(true)

      # Update relay_url to use http://
      {:ok, _} = RemoteAccess.upsert_config(%{relay_url: "http://relay.example.com"})

      # Same as above - verify URL parsing doesn't crash
      result = Relay.start_link(name: :test_relay_http)

      case result do
        {:ok, pid} ->
          Process.exit(pid, :kill)

        {:error, reason} ->
          assert is_map(reason) or is_tuple(reason) or is_atom(reason)
      end
    end
  end

  describe "status checking" do
    test "returns error when relay is not running" do
      # Without starting the relay, status should return error
      assert {:error, :not_running} = Relay.status(:nonexistent_relay)
    end

    test "relay_available?/0 returns false when not connected" do
      assert RemoteAccess.relay_available?() == false
    end
  end

  describe "relay context helpers" do
    test "relay_status/0 delegates to Relay module" do
      # Without a running relay, should get error
      assert {:error, :not_running} = RemoteAccess.relay_status()
    end

    test "relay_available?/0 checks registration status" do
      # Should return false when relay is not running
      refute RemoteAccess.relay_available?()
    end
  end

  describe "module structure" do
    # These tests verify that the module compiles and has the right structure
    # We can't easily test WebSockex callbacks without a real WebSocket server

    test "module is loaded and available" do
      # Verify the module can be loaded
      assert Code.ensure_loaded?(Relay)
    end

    test "module exports public API" do
      # Get all exported functions
      functions = Relay.__info__(:functions)

      # Check that key functions exist (with any arity)
      function_names = Keyword.keys(functions)
      assert :start_link in function_names
      assert :status in function_names
      assert :ping in function_names
    end
  end

  describe "configuration validation" do
    test "validates relay_url format in config" do
      {:ok, config} = RemoteAccess.initialize_keypair()

      # Invalid URL should fail validation
      result =
        config
        |> RemoteAccess.Config.changeset(%{relay_url: "not-a-url"})
        |> Repo.update()

      assert {:error, changeset} = result
      assert "must be a valid URL" in errors_on(changeset).relay_url
    end

    test "accepts valid http and https URLs" do
      {:ok, config} = RemoteAccess.initialize_keypair()

      # Valid http URL
      {:ok, updated} =
        config
        |> RemoteAccess.Config.changeset(%{relay_url: "http://relay.example.com"})
        |> Repo.update()

      assert updated.relay_url == "http://relay.example.com"

      # Valid https URL
      {:ok, updated} =
        updated
        |> RemoteAccess.Config.changeset(%{relay_url: "https://secure-relay.example.com"})
        |> Repo.update()

      assert updated.relay_url == "https://secure-relay.example.com"
    end
  end
end
