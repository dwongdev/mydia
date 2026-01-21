defmodule MetadataRelay.PairingTest do
  use ExUnit.Case, async: true

  alias MetadataRelay.Pairing
  alias MetadataRelay.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  @valid_node_addr Jason.encode!(%{
                     "relay_url" => "https://relay.example.com",
                     "node_id" => "abc123def456"
                   })

  describe "create_claim/2" do
    test "creates a claim with valid node_addr" do
      assert {:ok, claim} = Pairing.create_claim(@valid_node_addr)
      assert String.length(claim.code) == 6
      assert claim.node_addr == @valid_node_addr
      assert claim.expires_at != nil
    end

    test "returns error for invalid JSON node_addr" do
      assert {:error, changeset} = Pairing.create_claim("not-valid-json")
      assert %{node_addr: ["must be valid JSON"]} = errors_on(changeset)
    end

    test "respects custom TTL" do
      before = DateTime.utc_now()
      assert {:ok, claim} = Pairing.create_claim(@valid_node_addr, ttl_seconds: 600)
      after_plus_600 = DateTime.add(before, 600, :second)

      diff = DateTime.diff(claim.expires_at, after_plus_600, :second)
      assert abs(diff) < 2
    end

    test "respects custom code" do
      assert {:ok, claim} = Pairing.create_claim(@valid_node_addr, code: "CUSTOM")
      assert claim.code == "CUSTOM"
    end

    test "uppercases code" do
      assert {:ok, claim} = Pairing.create_claim(@valid_node_addr, code: "mycode")
      assert claim.code == "MYCODE"
    end
  end

  describe "get_claim/1" do
    test "returns node_addr for valid code" do
      {:ok, claim} = Pairing.create_claim(@valid_node_addr)
      assert {:ok, node_addr} = Pairing.get_claim(claim.code)
      assert node_addr == @valid_node_addr
    end

    test "returns error for non-existent code" do
      assert {:error, :not_found} = Pairing.get_claim("NONEXISTENT")
    end

    test "returns error for expired code" do
      {:ok, _claim} = Pairing.create_claim(@valid_node_addr, ttl_seconds: -1, code: "EXPTEST")
      assert {:error, :expired} = Pairing.get_claim("EXPTEST")
    end

    test "normalizes code (case insensitive)" do
      {:ok, claim} = Pairing.create_claim(@valid_node_addr)
      assert {:ok, _} = Pairing.get_claim(String.downcase(claim.code))
    end

    test "normalizes code (strips dashes and spaces)" do
      {:ok, claim} = Pairing.create_claim(@valid_node_addr, code: "ABCDEF")

      # Should work with dashes
      assert {:ok, _} = Pairing.get_claim("ABC-DEF")

      # Should work with spaces
      assert {:ok, _} = Pairing.get_claim("ABC DEF")

      # Should work with mixed
      assert {:ok, _} = Pairing.get_claim("abc-def")
    end
  end

  describe "delete_claim/1" do
    test "deletes existing claim" do
      {:ok, claim} = Pairing.create_claim(@valid_node_addr)
      assert :ok = Pairing.delete_claim(claim.code)

      # Should not be findable anymore
      assert {:error, :not_found} = Pairing.get_claim(claim.code)
    end

    test "returns error for non-existent claim" do
      assert {:error, :not_found} = Pairing.delete_claim("NONEXISTENT")
    end

    test "normalizes code on delete" do
      {:ok, claim} = Pairing.create_claim(@valid_node_addr, code: "DELETE")
      assert :ok = Pairing.delete_claim("del-ete")
    end
  end

  describe "cleanup_expired/1" do
    test "deletes expired claims beyond max age" do
      # Create an expired claim
      {:ok, _claim} = Pairing.create_claim(@valid_node_addr, ttl_seconds: -7200, code: "EXP001")

      # Run cleanup with 1 hour max age
      count = Pairing.cleanup_expired(3600)
      assert count == 1

      # Claim should be gone
      assert {:error, :not_found} = Pairing.get_claim("EXP001")
    end

    test "does not delete recently expired claims" do
      # Create a claim that just expired
      {:ok, _claim} = Pairing.create_claim(@valid_node_addr, ttl_seconds: -1, code: "RECENT")

      # Run cleanup with 1 hour max age - should not delete claims expired < 1 hour ago
      count = Pairing.cleanup_expired(3600)
      assert count == 0
    end

    test "does not delete valid claims" do
      {:ok, _claim} = Pairing.create_claim(@valid_node_addr, code: "VALID1")
      count = Pairing.cleanup_expired(0)
      assert count == 0
    end
  end

  # Helper functions

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
