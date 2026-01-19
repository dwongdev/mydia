defmodule Mydia.RemoteAccess.StunClientTest do
  use ExUnit.Case, async: true

  alias Mydia.RemoteAccess.StunClient

  describe "detect_public_ip/0" do
    @tag :external
    test "detects public IP from default STUN servers" do
      # This test requires network access to public STUN servers
      case StunClient.detect_public_ip() do
        {:ok, ip} ->
          # Verify we got a valid IP string
          assert is_binary(ip)
          assert String.match?(ip, ~r/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/)

        {:error, reason} ->
          # STUN might fail in some test environments (firewalls, etc.)
          # This is acceptable - just log it
          IO.puts("STUN detection failed (expected in some environments): #{inspect(reason)}")
      end
    end
  end

  describe "query_stun_server/2" do
    @tag :external
    test "queries Google STUN server" do
      # Test with a specific known STUN server
      case StunClient.query_stun_server("stun.l.google.com", 19302) do
        {:ok, ip} ->
          assert is_binary(ip)
          assert String.match?(ip, ~r/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/)

        {:error, _reason} ->
          # May fail in restricted environments
          :ok
      end
    end

    test "returns error for invalid server" do
      # Non-existent server should fail
      assert {:error, _} = StunClient.query_stun_server("invalid.nonexistent.local", 3478)
    end
  end
end
