defmodule MetadataRelay.TurnConfigTest do
  use ExUnit.Case, async: false

  alias MetadataRelay.TurnConfig

  @test_secret "test-secret-key-12345"

  setup do
    # Clean up environment before each test
    original_turn_uri = Application.get_env(:metadata_relay, :turn_uri)
    original_turn_secret = Application.get_env(:metadata_relay, :turn_secret)
    original_turn_enabled = Application.get_env(:metadata_relay, :turn_enabled)

    on_exit(fn ->
      if original_turn_uri do
        Application.put_env(:metadata_relay, :turn_uri, original_turn_uri)
      else
        Application.delete_env(:metadata_relay, :turn_uri)
      end

      if original_turn_secret do
        Application.put_env(:metadata_relay, :turn_secret, original_turn_secret)
      else
        Application.delete_env(:metadata_relay, :turn_secret)
      end

      if original_turn_enabled do
        Application.put_env(:metadata_relay, :turn_enabled, original_turn_enabled)
      else
        Application.delete_env(:metadata_relay, :turn_enabled)
      end
    end)

    :ok
  end

  describe "generate_ice_servers/0 without TURN" do
    test "returns only STUN servers when no TURN is configured" do
      Application.delete_env(:metadata_relay, :turn_uri)
      Application.delete_env(:metadata_relay, :turn_secret)
      Application.delete_env(:metadata_relay, :turn_enabled)

      servers = TurnConfig.generate_ice_servers()

      # Should have at least the Google STUN server
      assert length(servers) >= 1
      assert Enum.any?(servers, fn server ->
        server.urls == "stun:stun.l.google.com:19302"
      end)

      # Should not have any TURN servers
      refute Enum.any?(servers, fn server ->
        urls = if is_list(server.urls), do: server.urls, else: [server.urls]
        Enum.any?(urls, &String.starts_with?(&1, "turn:"))
      end)
    end
  end

  describe "generate_ice_servers/0 with external TURN" do
    test "returns TURN server with credentials when configured" do
      Application.put_env(:metadata_relay, :turn_uri, "turn:turn.example.com:3478")
      Application.put_env(:metadata_relay, :turn_secret, @test_secret)
      Application.put_env(:metadata_relay, :turn_enabled, false)

      servers = TurnConfig.generate_ice_servers()

      # Should have TURN server
      turn_server = Enum.find(servers, fn server ->
        case server.urls do
          urls when is_list(urls) -> Enum.any?(urls, &String.starts_with?(&1, "turn:"))
          url -> String.starts_with?(url, "turn:")
        end
      end)

      assert turn_server != nil
      assert turn_server.username != nil
      assert turn_server.credential != nil

      # Username should be timestamp:identifier format
      [timestamp_str, _identifier] = String.split(turn_server.username, ":", parts: 2)
      {timestamp, ""} = Integer.parse(timestamp_str)

      # Timestamp should be in the future (credential not expired)
      assert timestamp > System.os_time(:second)

      # Credential should be valid HMAC-SHA1
      expected_credential =
        :crypto.mac(:hmac, :sha, @test_secret, turn_server.username)
        |> Base.encode64()

      assert turn_server.credential == expected_credential
    end

    test "includes UDP, TCP and TLS variants for external TURN" do
      Application.put_env(:metadata_relay, :turn_uri, "turn:turn.example.com:3478")
      Application.put_env(:metadata_relay, :turn_secret, @test_secret)
      Application.put_env(:metadata_relay, :turn_enabled, false)

      servers = TurnConfig.generate_ice_servers()

      turn_server = Enum.find(servers, fn server ->
        is_list(server.urls) and Enum.any?(server.urls, &String.starts_with?(&1, "turn:"))
      end)

      assert turn_server != nil
      assert is_list(turn_server.urls)

      # Should have UDP, TCP, and TLS variants
      assert Enum.any?(turn_server.urls, &(&1 == "turn:turn.example.com:3478"))
      assert Enum.any?(turn_server.urls, &String.contains?(&1, "transport=tcp"))
      assert Enum.any?(turn_server.urls, &String.starts_with?(&1, "turns:"))
    end
  end

  describe "generate_ice_servers/1 with custom TTL" do
    test "respects custom TTL for credentials" do
      Application.put_env(:metadata_relay, :turn_uri, "turn:turn.example.com:3478")
      Application.put_env(:metadata_relay, :turn_secret, @test_secret)

      # 1 hour TTL
      servers = TurnConfig.generate_ice_servers(3600)

      turn_server = Enum.find(servers, fn server ->
        Map.has_key?(server, :username)
      end)

      [timestamp_str, _] = String.split(turn_server.username, ":", parts: 2)
      {timestamp, ""} = Integer.parse(timestamp_str)

      # Timestamp should be approximately now + 1 hour
      expected_timestamp = System.os_time(:second) + 3600
      assert abs(timestamp - expected_timestamp) < 5
    end
  end

  describe "integrated_turn_enabled?/0" do
    test "returns false when not configured" do
      Application.delete_env(:metadata_relay, :turn_enabled)
      refute TurnConfig.integrated_turn_enabled?()
    end

    test "returns false when explicitly disabled" do
      Application.put_env(:metadata_relay, :turn_enabled, false)
      refute TurnConfig.integrated_turn_enabled?()
    end

    test "returns true when enabled" do
      Application.put_env(:metadata_relay, :turn_enabled, true)
      assert TurnConfig.integrated_turn_enabled?()
    end
  end
end
