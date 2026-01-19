defmodule MetadataRelay.Relay.ResolveTest do
  use ExUnit.Case, async: true
  alias MetadataRelay.Relay
  alias MetadataRelay.Repo

  setup do
    # Use sandbox mode for database isolation
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    instance = insert_instance()
    {:ok, instance: instance}
  end

  describe "resolve_claim/1" do
    test "resolves valid claim", %{instance: instance} do
      {:ok, claim} = Relay.create_claim(instance, "user1")

      assert {:ok, result} = Relay.resolve_claim(claim.code)
      assert result.namespace =~ "mydia-claim:"
      assert result.expires_at == claim.expires_at
      assert is_list(result.rendezvous_points)
    end

    test "returns expired error for expired claim", %{instance: instance} do
      {:ok, claim} = Relay.create_claim(instance, "user1", ttl_seconds: -10)

      assert {:error, :expired} = Relay.resolve_claim(claim.code)
    end

    test "returns already_consumed for consumed claim", %{instance: instance} do
      {:ok, claim} = Relay.create_claim(instance, "user1")
      {:ok, _} = Relay.consume_claim(instance.instance_id, claim.id, "device1")

      assert {:error, :already_consumed} = Relay.resolve_claim(claim.code)
    end

    test "returns not_found for non-existent claim" do
      assert {:error, :not_found} = Relay.resolve_claim("NONEXISTENT")
    end
  end

  describe "lock_claim/1" do
    test "locks valid claim", %{instance: instance} do
      {:ok, claim} = Relay.create_claim(instance, "user1")

      assert {:ok, updated} = Relay.lock_claim(claim.code)
      assert updated.locked_at
      assert updated.lock_expires_at
      assert MetadataRelay.Relay.Claim.locked?(updated)
    end

    test "returns locked error if already locked", %{instance: instance} do
      {:ok, claim} = Relay.create_claim(instance, "user1")
      {:ok, _} = Relay.lock_claim(claim.code)

      assert {:error, :locked} = Relay.lock_claim(claim.code)
    end

    test "can re-lock after lock expires", %{instance: instance} do
      {:ok, claim} = Relay.create_claim(instance, "user1")
      {:ok, locked} = Relay.lock_claim(claim.code)

      # Update lock_expires_at to past
      past = DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.truncate(:second)

      {:ok, _} =
        locked
        |> Ecto.Changeset.change(lock_expires_at: past)
        |> MetadataRelay.Repo.update()

      # Should be able to lock again
      assert {:ok, _} = Relay.lock_claim(claim.code)
    end
  end

  defp insert_instance do
    key = :crypto.strong_rand_bytes(32)

    {:ok, instance} =
      Relay.register_instance(%{
        instance_id: Ecto.UUID.generate(),
        public_key: key,
        direct_urls: []
      })

    instance
  end
end
