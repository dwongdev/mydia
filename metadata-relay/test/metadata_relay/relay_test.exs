defmodule MetadataRelay.RelayTest do
  use ExUnit.Case, async: true

  alias MetadataRelay.Relay
  alias MetadataRelay.Repo

  setup do
    # Use sandbox mode for database isolation
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  describe "register_instance/1" do
    test "creates a new instance with valid attributes" do
      public_key = :crypto.strong_rand_bytes(32)

      attrs = %{
        instance_id: "test-instance-#{System.unique_integer()}",
        public_key: public_key,
        direct_urls: ["https://mydia.local:4000"]
      }

      assert {:ok, instance} = Relay.register_instance(attrs)
      assert instance.instance_id == attrs.instance_id
      assert instance.public_key == public_key
      assert instance.direct_urls == ["https://mydia.local:4000"]
      assert instance.online == false
    end

    test "updates existing instance on conflict" do
      public_key1 = :crypto.strong_rand_bytes(32)
      public_key2 = :crypto.strong_rand_bytes(32)
      instance_id = "test-instance-#{System.unique_integer()}"

      attrs1 = %{
        instance_id: instance_id,
        public_key: public_key1,
        direct_urls: ["https://url1.local:4000"]
      }

      attrs2 = %{
        instance_id: instance_id,
        public_key: public_key2,
        direct_urls: ["https://url2.local:4000"]
      }

      assert {:ok, instance1} = Relay.register_instance(attrs1)
      assert {:ok, instance2} = Relay.register_instance(attrs2)

      # Should be the same record
      assert instance1.id == instance2.id
      # But with updated values
      assert instance2.public_key == public_key2
      assert instance2.direct_urls == ["https://url2.local:4000"]
    end

    test "returns error for invalid public key size" do
      attrs = %{
        instance_id: "test-instance-#{System.unique_integer()}",
        public_key: :crypto.strong_rand_bytes(16),
        direct_urls: []
      }

      assert {:error, changeset} = Relay.register_instance(attrs)
      assert %{public_key: ["must be a 32-byte Curve25519 public key"]} = errors_on(changeset)
    end
  end

  describe "get_instance/1" do
    test "returns instance by instance_id" do
      {:ok, instance} = create_instance()
      assert found = Relay.get_instance(instance.instance_id)
      assert found.id == instance.id
    end

    test "returns nil for non-existent instance" do
      assert Relay.get_instance("non-existent") == nil
    end
  end

  describe "update_heartbeat/2" do
    test "updates last_seen_at and sets online to true" do
      {:ok, instance} = create_instance()
      assert instance.online == false
      assert instance.last_seen_at == nil

      assert {:ok, updated} = Relay.update_heartbeat(instance)
      assert updated.online == true
      assert updated.last_seen_at != nil
    end

    test "updates direct_urls" do
      {:ok, instance} = create_instance()
      new_urls = ["https://new.local:4000", "https://new2.local:4000"]

      assert {:ok, updated} = Relay.update_heartbeat(instance, %{direct_urls: new_urls})
      assert updated.direct_urls == new_urls
    end
  end

  describe "set_online/1 and set_offline/1" do
    test "sets instance online and offline" do
      {:ok, instance} = create_instance()
      assert instance.online == false

      assert {:ok, online_instance} = Relay.set_online(instance)
      assert online_instance.online == true

      assert {:ok, offline_instance} = Relay.set_offline(online_instance)
      assert offline_instance.online == false
    end
  end

  describe "create_claim/3" do
    test "creates a claim code for an instance" do
      {:ok, instance} = create_instance()
      user_id = "user-#{System.unique_integer()}"

      assert {:ok, claim} = Relay.create_claim(instance, user_id)
      assert claim.user_id == user_id
      assert claim.instance_id == instance.id
      assert String.length(claim.code) == 6
      assert claim.expires_at != nil
      assert claim.consumed_at == nil
    end

    test "respects custom TTL" do
      {:ok, instance} = create_instance()
      user_id = "user-#{System.unique_integer()}"

      before = DateTime.utc_now()
      assert {:ok, claim} = Relay.create_claim(instance, user_id, ttl_seconds: 600)
      after_plus_600 = DateTime.add(before, 600, :second)

      # expires_at should be approximately 600 seconds from now
      diff = DateTime.diff(claim.expires_at, after_plus_600, :second)
      assert abs(diff) < 2
    end
  end

  describe "redeem_claim/1" do
    test "returns claim info for valid code" do
      {:ok, instance} = create_instance()
      {:ok, _} = Relay.set_online(instance)
      user_id = "user-#{System.unique_integer()}"
      {:ok, claim} = Relay.create_claim(instance, user_id)

      assert {:ok, info} = Relay.redeem_claim(claim.code)
      assert info.claim_id == claim.id
      assert info.instance_id == instance.instance_id
      assert info.user_id == user_id
    end

    test "returns error for non-existent code" do
      assert {:error, :not_found} = Relay.redeem_claim("NONEXISTENT")
    end

    test "returns error for consumed code" do
      {:ok, instance} = create_instance()
      {:ok, _} = Relay.set_online(instance)
      {:ok, claim} = Relay.create_claim(instance, "user-1")
      {:ok, _} = Relay.consume_claim(instance.instance_id, claim.id, "device-1")

      assert {:error, :already_consumed} = Relay.redeem_claim(claim.code)
    end

    test "returns error for expired code" do
      {:ok, instance} = create_instance()
      {:ok, claim} = Relay.create_claim(instance, "user-1", ttl_seconds: -1)

      assert {:error, :expired} = Relay.redeem_claim(claim.code)
    end
  end

  describe "consume_claim/3" do
    test "marks claim as consumed when authenticated instance matches" do
      {:ok, instance} = create_instance()
      {:ok, claim} = Relay.create_claim(instance, "user-1")
      device_id = "device-#{System.unique_integer()}"

      assert {:ok, consumed} = Relay.consume_claim(instance.instance_id, claim.id, device_id)
      assert consumed.consumed_at != nil
      assert consumed.consumed_by_device_id == device_id
    end

    test "returns error when already consumed" do
      {:ok, instance} = create_instance()
      {:ok, claim} = Relay.create_claim(instance, "user-1")
      {:ok, _} = Relay.consume_claim(instance.instance_id, claim.id, "device-1")

      assert {:error, :already_consumed} =
               Relay.consume_claim(instance.instance_id, claim.id, "device-2")
    end

    test "returns error when authenticated instance does not match claim owner" do
      {:ok, instance1} = create_instance()
      {:ok, instance2} = create_instance()
      {:ok, claim} = Relay.create_claim(instance1, "user-1")
      device_id = "device-#{System.unique_integer()}"

      # Try to consume claim with wrong instance credentials
      assert {:error, :unauthorized} = Relay.consume_claim(instance2.instance_id, claim.id, device_id)

      # Verify claim was not consumed
      refreshed_claim = Repo.get(MetadataRelay.Relay.Claim, claim.id)
      assert refreshed_claim.consumed_at == nil
    end

    test "returns error when claim does not exist" do
      {:ok, instance} = create_instance()
      fake_claim_id = Ecto.UUID.generate()

      assert {:error, :not_found} =
               Relay.consume_claim(instance.instance_id, fake_claim_id, "device-1")
    end
  end

  describe "generate_instance_token/1 and verify_instance_token/1" do
    test "generates and verifies valid token" do
      {:ok, instance} = create_instance()
      token = Relay.generate_instance_token(instance)

      assert {:ok, instance_id} = Relay.verify_instance_token(token)
      assert instance_id == instance.instance_id
    end

    test "returns error for invalid token" do
      assert {:error, :invalid_token} = Relay.verify_instance_token("invalid-token")
    end

    test "returns error for tampered token" do
      {:ok, instance} = create_instance()
      token = Relay.generate_instance_token(instance)
      tampered = token <> "x"

      assert {:error, :invalid_token} = Relay.verify_instance_token(tampered)
    end
  end

  describe "get_connection_info/1" do
    test "returns connection info for existing instance" do
      {:ok, instance} = create_instance()
      {:ok, _} = Relay.set_online(instance)

      assert {:ok, info} = Relay.get_connection_info(instance.instance_id)
      assert info.instance_id == instance.instance_id
      assert info.online == true
      assert is_binary(info.public_key)
    end

    test "returns error for non-existent instance" do
      assert {:error, :not_found} = Relay.get_connection_info("non-existent")
    end
  end

  # Helper functions

  defp create_instance(attrs \\ %{}) do
    default_attrs = %{
      instance_id: "test-instance-#{System.unique_integer()}",
      public_key: :crypto.strong_rand_bytes(32),
      direct_urls: []
    }

    Relay.register_instance(Map.merge(default_attrs, attrs))
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
