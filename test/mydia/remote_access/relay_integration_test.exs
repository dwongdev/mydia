defmodule Mydia.RemoteAccess.RelayIntegrationTest do
  use Mydia.DataCase, async: false

  alias Mydia.RemoteAccess

  @moduletag :external

  describe "relay lifecycle integration" do
    test "relay service is conditionally started based on remote access configuration" do
      # Initially, with no config, relay should not be registered
      assert RemoteAccess.relay_status() == {:error, :not_running}
      assert RemoteAccess.relay_available?() == false

      # After initializing but leaving disabled, relay still shouldn't start
      {:ok, _config} = RemoteAccess.initialize_keypair()
      assert RemoteAccess.relay_status() == {:error, :not_running}

      # Note: In production, when remote access is enabled via toggle_remote_access,
      # the application would need to be restarted for the relay service to start,
      # or a dynamic supervisor would need to be implemented to start/stop the relay
      # based on the enabled flag changes.

      # This is expected behavior as the relay is only added to the supervision tree
      # at application startup based on the config state at that time.
    end
  end

  describe "relay configuration flow" do
    test "complete configuration workflow" do
      # Step 1: Initialize keypair (creates config but disabled)
      {:ok, config} = RemoteAccess.initialize_keypair()
      assert config.enabled == false
      assert config.relay_url == "https://relay.mydia.app"
      assert config.instance_id != nil
      assert config.static_public_key != nil

      # Step 2: Enable remote access
      {:ok, updated_config} = RemoteAccess.toggle_remote_access(true)
      assert updated_config.enabled == true

      # Step 3: Check relay status (will be :not_running since we're in test mode)
      # In production, after restart, the relay would automatically connect
      assert RemoteAccess.relay_status() == {:error, :not_running}

      # Step 4: Disable remote access
      {:ok, disabled_config} = RemoteAccess.toggle_remote_access(false)
      assert disabled_config.enabled == false
    end

    test "custom relay URL configuration" do
      {:ok, _config} = RemoteAccess.initialize_keypair()

      # Update relay URL
      custom_url = "https://custom-relay.example.com"
      {:ok, updated} = RemoteAccess.upsert_config(%{relay_url: custom_url})
      assert updated.relay_url == custom_url

      # Enable and verify config
      {:ok, enabled} = RemoteAccess.toggle_remote_access(true)
      assert enabled.enabled == true
      assert enabled.relay_url == custom_url
    end
  end
end
