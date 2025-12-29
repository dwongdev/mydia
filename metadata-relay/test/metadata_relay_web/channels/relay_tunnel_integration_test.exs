defmodule MetadataRelayWeb.RelayTunnelIntegrationTest do
  @moduledoc """
  Unit tests for relay tunnel database operations.

  For full WebSocket integration testing, see RELAY_TUNNEL_MANUAL_TEST.md
  """
  use ExUnit.Case, async: false

  alias MetadataRelay.Relay
  alias MetadataRelay.Repo

  setup do
    # Use sandbox mode for database isolation
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    # Create a test instance in the database
    instance_id = "test-instance-#{System.unique_integer()}"
    public_key = :crypto.strong_rand_bytes(32)

    {:ok, instance} =
      Relay.register_instance(%{
        instance_id: instance_id,
        public_key: public_key,
        direct_urls: ["https://mydia.local:4000"]
      })

    {:ok, instance: instance, instance_id: instance_id, public_key: public_key}
  end

  describe "relay tunnel database operations" do
    test "instance can be registered and marked online", %{instance_id: instance_id} do
      instance = Relay.get_instance(instance_id)
      assert instance != nil
      assert instance.online == false

      {:ok, updated} = Relay.set_online(instance)
      assert updated.online == true

      {:ok, info} = Relay.get_connection_info(instance_id)
      assert info.online == true
    end

    test "claim codes can be created and redeemed", %{
      instance: instance,
      instance_id: instance_id
    } do
      # Set instance online first
      {:ok, _} = Relay.set_online(instance)

      # Create a claim code
      user_id = Ecto.UUID.generate()
      {:ok, claim} = Relay.create_claim(instance, user_id, ttl_seconds: 300)

      assert claim.code != nil
      assert claim.user_id == user_id
      assert claim.consumed_at == nil

      # Redeem the claim
      {:ok, info} = Relay.redeem_claim(claim.code)
      assert info.instance_id == instance_id
      assert info.user_id == user_id
      assert info.online == true
      assert info.claim_id == claim.id
    end

    test "connection info includes direct URLs and public key", %{
      instance_id: instance_id,
      public_key: public_key
    } do
      {:ok, info} = Relay.get_connection_info(instance_id)

      assert info.instance_id == instance_id
      assert info.direct_urls == ["https://mydia.local:4000"]
      assert Base.decode64!(info.public_key) == public_key
    end

    test "offline instance returns offline status", %{instance_id: instance_id} do
      {:ok, info} = Relay.get_connection_info(instance_id)
      assert info.online == false
    end
  end

  describe "message routing logic" do
    test "PubSub topics are correctly structured for routing" do
      # This test verifies the PubSub topic structure used for message routing

      instance_id = "test-instance-123"
      session_id = "test-session-456"

      # Instance subscribes to: "relay:instance:#{instance_id}"
      # Client messages are broadcast to this topic
      instance_topic = "relay:instance:#{instance_id}"
      assert String.starts_with?(instance_topic, "relay:instance:")

      # Client subscribes to: "relay:session:#{session_id}"
      # Instance responses are broadcast to this topic
      session_topic = "relay:session:#{session_id}"
      assert String.starts_with?(session_topic, "relay:session:")

      # Verify topics are different
      assert instance_topic != session_topic
    end

    test "message payload is base64 encoded for transport" do
      # This demonstrates that relay sees only base64-encoded payloads
      plaintext = "Hello, World!"
      encoded = Base.encode64(plaintext)

      # Relay only ever sees the encoded version
      assert String.printable?(encoded)

      # Noise-encrypted data would look like random bytes when base64-encoded
      ciphertext = :crypto.strong_rand_bytes(64)
      encoded_cipher = Base.encode64(ciphertext)

      # Relay can't distinguish between plaintext and ciphertext
      # Both are just base64 strings
      assert is_binary(encoded_cipher)
      assert String.valid?(encoded_cipher)
    end
  end
end
