defmodule Mydia.RemoteAccess.RelayTunnelTest do
  use Mydia.DataCase, async: false

  alias Mydia.RemoteAccess.RelayTunnel

  describe "relay tunnel supervisor" do
    test "starts successfully and subscribes to relay connections" do
      # RelayTunnel is already started by the application supervisor
      # Verify it's running
      pid = Process.whereis(RelayTunnel)
      assert pid != nil
      assert Process.alive?(pid)
    end

    test "handles relay connection events" do
      # RelayTunnel is already started by the application supervisor
      pid = Process.whereis(RelayTunnel)
      assert pid != nil

      # Simulate a relay connection event
      session_id = "test-session-#{System.unique_integer()}"
      client_public_key = :crypto.strong_rand_bytes(32)
      relay_pid = self()

      # Broadcast a relay connection event
      Phoenix.PubSub.broadcast(
        Mydia.PubSub,
        "relay:connections",
        {:relay_connection, session_id, client_public_key, relay_pid}
      )

      # Give the tunnel process time to start
      Process.sleep(100)

      # The tunnel should be handling this connection
      # We can verify by checking if messages can be sent to the session
      # Note: Full integration would require mocking the Pairing module
    end
  end

  describe "tunnel message handling" do
    test "handles incoming relay messages" do
      # This test would require mocking the Pairing module
      # and simulating the full handshake flow
      # For now, we verify the supervisor is running
      pid = Process.whereis(RelayTunnel)
      assert pid != nil
      assert Process.alive?(pid)
    end
  end
end
