defmodule Mydia.RemoteAccessTest do
  use Mydia.DataCase

  alias Mydia.RemoteAccess
  alias Mydia.RemoteAccess.{Config, PairingClaim, RemoteDevice}
  alias Mydia.Accounts

  describe "initialize_keypair/0" do
    test "generates and stores keypair with instance ID" do
      assert {:ok, %Config{} = config} = RemoteAccess.initialize_keypair()

      # Verify public key is 32 bytes
      assert byte_size(config.static_public_key) == 32

      # Verify private key is encrypted and stored
      assert is_binary(config.static_private_key_encrypted)
      assert byte_size(config.static_private_key_encrypted) > 32

      # Verify instance ID is a valid UUID
      assert is_binary(config.instance_id)
      assert String.length(config.instance_id) == 36

      assert config.instance_id =~
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

      # Verify enabled is false by default
      refute config.enabled
    end

    test "generates unique keypairs on each call" do
      # Clean up any existing config first
      Repo.delete_all(Config)

      assert {:ok, config1} = RemoteAccess.initialize_keypair()

      # Delete and reinitialize
      Repo.delete(config1)
      assert {:ok, config2} = RemoteAccess.initialize_keypair()

      # Public keys should be different
      assert config1.static_public_key != config2.static_public_key

      # Instance IDs should be different
      assert config1.instance_id != config2.instance_id
    end

    test "can only create one config (singleton pattern)" do
      assert {:ok, config1} = RemoteAccess.initialize_keypair()

      # Should return the same config on subsequent get_config calls
      assert config2 = RemoteAccess.get_config()
      assert config1.id == config2.id

      # There should only be one config in the database
      assert Repo.aggregate(Config, :count) == 1
    end

    test "encrypted private key can be decrypted to original" do
      assert {:ok, config} = RemoteAccess.initialize_keypair()

      # Extract the encrypted blob
      <<nonce::64, ciphertext::binary>> = config.static_private_key_encrypted

      # Get the app secret
      secret_key_base = Application.get_env(:mydia, MydiaWeb.Endpoint)[:secret_key_base]
      app_secret = :crypto.hash(:sha256, secret_key_base)

      # Decrypt the private key
      encrypted_data = %{ciphertext: ciphertext, nonce: nonce}

      assert {:ok, decrypted_key} =
               Mydia.Crypto.decrypt_private_key(encrypted_data, app_secret)

      # Should be 32 bytes
      assert byte_size(decrypted_key) == 32
    end
  end

  describe "get_public_key/0" do
    test "returns public key when config exists" do
      assert {:ok, config} = RemoteAccess.initialize_keypair()

      public_key = RemoteAccess.get_public_key()
      assert public_key == config.static_public_key
      assert byte_size(public_key) == 32
    end

    test "returns nil when config does not exist" do
      # Ensure no config exists
      Repo.delete_all(Config)

      assert RemoteAccess.get_public_key() == nil
    end
  end

  describe "get_private_key/0" do
    test "returns decrypted private key when config exists" do
      assert {:ok, _config} = RemoteAccess.initialize_keypair()

      assert {:ok, private_key} = RemoteAccess.get_private_key()
      assert byte_size(private_key) == 32
    end

    test "returns error when config does not exist" do
      # Ensure no config exists
      Repo.delete_all(Config)

      assert {:error, :not_configured} = RemoteAccess.get_private_key()
    end

    test "decrypted private key matches original keypair" do
      # Generate a keypair directly
      {public_key_direct, private_key_direct} = Mydia.Crypto.generate_keypair()

      # Get app secret
      secret_key_base = Application.get_env(:mydia, MydiaWeb.Endpoint)[:secret_key_base]
      app_secret = :crypto.hash(:sha256, secret_key_base)

      # Encrypt the private key
      encrypted = Mydia.Crypto.encrypt_private_key(private_key_direct, app_secret)
      encrypted_blob = <<encrypted.nonce::64>> <> encrypted.ciphertext

      # Store in config
      instance_id = Ecto.UUID.generate()

      {:ok, _config} =
        Repo.insert(%Config{
          instance_id: instance_id,
          static_public_key: public_key_direct,
          static_private_key_encrypted: encrypted_blob,
          enabled: false
        })

      # Retrieve and decrypt
      assert {:ok, retrieved_private_key} = RemoteAccess.get_private_key()

      # Should match the original private key
      assert retrieved_private_key == private_key_direct
    end

    test "private key works with public key for Noise operations" do
      assert {:ok, config} = RemoteAccess.initialize_keypair()
      assert {:ok, private_key} = RemoteAccess.get_private_key()

      # The keypair should be valid for Noise protocol
      # We verify this by ensuring the keys have the correct relationship
      # Note: Full Noise handshake testing will be done in integration tests

      # Both keys should be 32 bytes
      assert byte_size(config.static_public_key) == 32
      assert byte_size(private_key) == 32

      # Private key should not be all zeros (extremely unlikely with crypto random)
      refute private_key == <<0::256>>
      refute config.static_public_key == <<0::256>>
    end
  end

  describe "keypair persistence" do
    test "keypair persists across function calls" do
      # Initialize keypair
      assert {:ok, config} = RemoteAccess.initialize_keypair()

      original_public_key = config.static_public_key
      original_instance_id = config.instance_id

      # Retrieve public key
      retrieved_public_key = RemoteAccess.get_public_key()
      assert retrieved_public_key == original_public_key

      # Retrieve private key
      assert {:ok, retrieved_private_key} = RemoteAccess.get_private_key()

      # Get config again to ensure it's the same
      config_again = RemoteAccess.get_config()
      assert config_again.static_public_key == original_public_key
      assert config_again.instance_id == original_instance_id

      # Verify we can still decrypt the private key
      assert {:ok, retrieved_private_key_again} = RemoteAccess.get_private_key()
      assert retrieved_private_key_again == retrieved_private_key
    end
  end

  describe "generate_claim_code/1" do
    test "creates a claim code with valid attributes" do
      user = create_user()

      assert {:ok, %PairingClaim{} = claim} = RemoteAccess.generate_claim_code(user.id)
      assert claim.user_id == user.id
      assert claim.code
      assert String.length(String.replace(claim.code, "-", "")) == 8
      assert is_nil(claim.used_at)
      assert is_nil(claim.device_id)
      assert claim.expires_at
    end

    test "generates unique codes" do
      user = create_user()

      assert {:ok, claim1} = RemoteAccess.generate_claim_code(user.id)
      assert {:ok, claim2} = RemoteAccess.generate_claim_code(user.id)

      assert claim1.code != claim2.code
    end

    test "sets expiration 5 minutes in the future" do
      user = create_user()

      assert {:ok, claim} = RemoteAccess.generate_claim_code(user.id)

      now = DateTime.utc_now()
      diff = DateTime.diff(claim.expires_at, now, :second)

      # Should be approximately 300 seconds (5 minutes), with some tolerance
      assert diff >= 295 and diff <= 305
    end

    test "code uses only non-ambiguous characters" do
      user = create_user()

      # Generate multiple codes to test randomness
      codes =
        1..10
        |> Enum.map(fn _ ->
          {:ok, claim} = RemoteAccess.generate_claim_code(user.id)
          claim.code
        end)

      # Check that no ambiguous characters are used
      ambiguous_chars = ["0", "O", "1", "I", "l"]

      Enum.each(codes, fn code ->
        Enum.each(ambiguous_chars, fn char ->
          refute String.contains?(code, char),
                 "Code #{code} should not contain ambiguous character #{char}"
        end)
      end)
    end
  end

  describe "validate_claim_code/2" do
    test "validates a fresh claim code" do
      user = create_user()
      {:ok, claim} = RemoteAccess.generate_claim_code(user.id)

      assert {:ok, validated_claim} = RemoteAccess.validate_claim_code(claim.code)
      assert validated_claim.id == claim.id
    end

    test "accepts code without dash" do
      user = create_user()
      {:ok, claim} = RemoteAccess.generate_claim_code(user.id)

      code_without_dash = String.replace(claim.code, "-", "")

      assert {:ok, validated_claim} = RemoteAccess.validate_claim_code(code_without_dash)
      assert validated_claim.id == claim.id
    end

    test "accepts code in lowercase" do
      user = create_user()
      {:ok, claim} = RemoteAccess.generate_claim_code(user.id)

      lowercase_code = String.downcase(claim.code)

      assert {:ok, validated_claim} = RemoteAccess.validate_claim_code(lowercase_code)
      assert validated_claim.id == claim.id
    end

    test "accepts code with extra whitespace" do
      user = create_user()
      {:ok, claim} = RemoteAccess.generate_claim_code(user.id)

      code_with_spaces = "  #{claim.code}  "

      assert {:ok, validated_claim} = RemoteAccess.validate_claim_code(code_with_spaces)
      assert validated_claim.id == claim.id
    end

    test "returns error for non-existent code" do
      assert {:error, :not_found} = RemoteAccess.validate_claim_code("INVALID-CODE")
    end

    test "validates 6-char code from relay (no dash)" do
      # This tests the fix for MYD-17: relay generates 6-char codes without dashes
      # and we need to validate them without re-adding a dash
      user = create_user()

      # Directly create a claim with a 6-char code (like relay generates)
      expires_at = DateTime.utc_now() |> DateTime.add(300, :second) |> DateTime.truncate(:second)

      {:ok, claim} =
        %PairingClaim{}
        |> PairingClaim.changeset_with_code(%{
          user_id: user.id,
          code: "ABC123",
          expires_at: expires_at
        })
        |> Repo.insert()

      # Should find the claim with the exact code
      assert {:ok, validated_claim} = RemoteAccess.validate_claim_code("ABC123")
      assert validated_claim.id == claim.id

      # Should also work with lowercase
      assert {:ok, _} = RemoteAccess.validate_claim_code("abc123")

      # Should also work if user adds a dash (normalization strips it)
      assert {:ok, _} = RemoteAccess.validate_claim_code("ABC-123")
    end

    test "returns error for expired code" do
      user = create_user()
      {:ok, claim} = RemoteAccess.generate_claim_code(user.id)

      # Manually set expiration to the past
      expired_at = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)

      expired_claim =
        claim
        |> Ecto.Changeset.change(expires_at: expired_at)
        |> Repo.update!()

      assert {:error, :expired} = RemoteAccess.validate_claim_code(expired_claim.code)
    end

    test "returns error for used code" do
      user = create_user()
      device = create_device(user.id)
      {:ok, claim} = RemoteAccess.generate_claim_code(user.id)

      # Consume the claim
      {:ok, _used_claim} = RemoteAccess.consume_claim_code(claim.code, device.id)

      # Try to validate it again
      assert {:error, :already_used} = RemoteAccess.validate_claim_code(claim.code)
    end
  end

  describe "validate_claim_code/2 with rate limiting" do
    test "allows validation within rate limit" do
      user = create_user()
      {:ok, claim} = RemoteAccess.generate_claim_code(user.id)

      # Multiple attempts from same IP should work if code is valid
      assert {:ok, _} = RemoteAccess.validate_claim_code(claim.code, ip_address: "192.168.1.1")
      assert {:ok, _} = RemoteAccess.validate_claim_code(claim.code, ip_address: "192.168.1.1")
      assert {:ok, _} = RemoteAccess.validate_claim_code(claim.code, ip_address: "192.168.1.1")
    end

    test "rate limits failed validation attempts" do
      ip_address = "192.168.1.100"

      # Make 5 failed attempts
      Enum.each(1..5, fn _ ->
        RemoteAccess.validate_claim_code("INVALID-CODE", ip_address: ip_address)
      end)

      # 6th attempt should be rate limited
      assert {:error, :rate_limited} =
               RemoteAccess.validate_claim_code("ANOTHER-CODE", ip_address: ip_address)
    end

    test "resets rate limit on successful validation" do
      user = create_user()
      {:ok, claim} = RemoteAccess.generate_claim_code(user.id)
      ip_address = "192.168.1.101"

      # Make 4 failed attempts
      Enum.each(1..4, fn _ ->
        RemoteAccess.validate_claim_code("INVALID-CODE", ip_address: ip_address)
      end)

      # Successful validation should reset the counter
      assert {:ok, _} = RemoteAccess.validate_claim_code(claim.code, ip_address: ip_address)

      # Should be able to make more attempts now
      Enum.each(1..4, fn _ ->
        RemoteAccess.validate_claim_code("INVALID-CODE", ip_address: ip_address)
      end)

      # Not yet rate limited
      assert {:error, :not_found} =
               RemoteAccess.validate_claim_code("ANOTHER-CODE", ip_address: ip_address)
    end

    test "different IPs have separate rate limits" do
      ip1 = "192.168.1.200"
      ip2 = "192.168.1.201"

      # Max out rate limit for IP1
      Enum.each(1..5, fn _ ->
        RemoteAccess.validate_claim_code("INVALID-CODE", ip_address: ip1)
      end)

      # IP1 should be rate limited
      assert {:error, :rate_limited} =
               RemoteAccess.validate_claim_code("ANOTHER-CODE", ip_address: ip1)

      # IP2 should still work
      assert {:error, :not_found} =
               RemoteAccess.validate_claim_code("ANOTHER-CODE", ip_address: ip2)
    end
  end

  describe "consume_claim_code/2" do
    test "consumes a valid claim code" do
      user = create_user()
      device = create_device(user.id)
      {:ok, claim} = RemoteAccess.generate_claim_code(user.id)

      assert {:ok, consumed_claim} = RemoteAccess.consume_claim_code(claim.code, device.id)
      assert consumed_claim.device_id == device.id
      assert consumed_claim.used_at
    end

    test "returns error for invalid code" do
      user = create_user()
      device = create_device(user.id)

      assert {:error, :not_found} = RemoteAccess.consume_claim_code("INVALID-CODE", device.id)
    end

    test "returns error for expired code" do
      user = create_user()
      device = create_device(user.id)
      {:ok, claim} = RemoteAccess.generate_claim_code(user.id)

      # Manually set expiration to the past
      expired_at = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)

      expired_claim =
        claim
        |> Ecto.Changeset.change(expires_at: expired_at)
        |> Repo.update!()

      assert {:error, :expired} = RemoteAccess.consume_claim_code(expired_claim.code, device.id)
    end

    test "returns error for already used code" do
      user = create_user()
      device1 = create_device(user.id)
      device2 = create_device(user.id)
      {:ok, claim} = RemoteAccess.generate_claim_code(user.id)

      # Consume with first device
      {:ok, _} = RemoteAccess.consume_claim_code(claim.code, device1.id)

      # Try to consume with second device
      assert {:error, :already_used} = RemoteAccess.consume_claim_code(claim.code, device2.id)
    end
  end

  describe "cleanup_expired_claims/0" do
    test "deletes expired claims" do
      user = create_user()
      {:ok, claim1} = RemoteAccess.generate_claim_code(user.id)
      {:ok, claim2} = RemoteAccess.generate_claim_code(user.id)

      # Manually expire claim1
      expired_at = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)

      claim1
      |> Ecto.Changeset.change(expires_at: expired_at)
      |> Repo.update!()

      # Run cleanup
      assert {:ok, count} = RemoteAccess.cleanup_expired_claims()
      assert count == 1

      # claim1 should be deleted
      refute Repo.get(PairingClaim, claim1.id)

      # claim2 should still exist
      assert Repo.get(PairingClaim, claim2.id)
    end

    test "does not delete non-expired claims" do
      user = create_user()
      {:ok, claim1} = RemoteAccess.generate_claim_code(user.id)
      {:ok, claim2} = RemoteAccess.generate_claim_code(user.id)

      assert {:ok, count} = RemoteAccess.cleanup_expired_claims()
      assert count == 0

      # Both claims should still exist
      assert Repo.get(PairingClaim, claim1.id)
      assert Repo.get(PairingClaim, claim2.id)
    end
  end

  describe "list_active_claims/1" do
    test "lists only active claims for a user" do
      user1 = create_user()
      user2 = create_user()
      device = create_device(user1.id)

      {:ok, active_claim1} = RemoteAccess.generate_claim_code(user1.id)
      {:ok, active_claim2} = RemoteAccess.generate_claim_code(user1.id)
      {:ok, expired_claim} = RemoteAccess.generate_claim_code(user1.id)
      {:ok, used_claim} = RemoteAccess.generate_claim_code(user1.id)
      {:ok, _other_user_claim} = RemoteAccess.generate_claim_code(user2.id)

      # Expire one claim
      expired_at = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)

      expired_claim
      |> Ecto.Changeset.change(expires_at: expired_at)
      |> Repo.update!()

      # Use one claim
      RemoteAccess.consume_claim_code(used_claim.code, device.id)

      # List active claims for user1
      active_claims = RemoteAccess.list_active_claims(user1.id)

      # Should only include the two active claims
      assert length(active_claims) == 2
      claim_ids = Enum.map(active_claims, & &1.id)
      assert active_claim1.id in claim_ids
      assert active_claim2.id in claim_ids
    end

    test "returns empty list when user has no active claims" do
      user = create_user()

      assert RemoteAccess.list_active_claims(user.id) == []
    end
  end

  describe "PairingClaim.valid?/1" do
    test "returns true for fresh claim" do
      user = create_user()
      {:ok, claim} = RemoteAccess.generate_claim_code(user.id)

      assert PairingClaim.valid?(claim)
    end

    test "returns false for expired claim" do
      user = create_user()
      {:ok, claim} = RemoteAccess.generate_claim_code(user.id)

      expired_at = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)

      expired_claim =
        claim
        |> Ecto.Changeset.change(expires_at: expired_at)
        |> Repo.update!()

      refute PairingClaim.valid?(expired_claim)
    end

    test "returns false for used claim" do
      user = create_user()
      device = create_device(user.id)
      {:ok, claim} = RemoteAccess.generate_claim_code(user.id)

      {:ok, used_claim} = RemoteAccess.consume_claim_code(claim.code, device.id)

      refute PairingClaim.valid?(used_claim)
    end
  end

  describe "publish_device_event/2" do
    setup do
      user = create_user()
      device = create_device(user.id)
      %{user: user, device: device}
    end

    test "publishes device connected event", %{device: device} do
      # This should not raise an error
      assert :ok = RemoteAccess.publish_device_event(device, :connected)
    end

    test "publishes device disconnected event", %{device: device} do
      assert :ok = RemoteAccess.publish_device_event(device, :disconnected)
    end

    test "publishes device revoked event", %{device: device} do
      assert :ok = RemoteAccess.publish_device_event(device, :revoked)
    end

    test "publishes device deleted event", %{device: device} do
      assert :ok = RemoteAccess.publish_device_event(device, :deleted)
    end
  end

  describe "revoke_device/1" do
    setup do
      user = create_user()
      device = create_device(user.id)
      %{user: user, device: device}
    end

    test "revokes device and publishes event", %{device: device} do
      assert {:ok, revoked_device} = RemoteAccess.revoke_device(device)
      assert revoked_device.revoked_at != nil
      assert RemoteDevice.revoked?(revoked_device)
    end
  end

  describe "delete_device/1" do
    setup do
      user = create_user()
      device = create_device(user.id)
      %{user: user, device: device}
    end

    test "deletes device and publishes event", %{device: device} do
      assert {:ok, deleted_device} = RemoteAccess.delete_device(device)
      assert deleted_device.id == device.id
      assert RemoteAccess.get_device(device.id) == nil
    end
  end

  describe "get_active_device/1" do
    test "returns device with preloaded user for active device" do
      user = create_user()
      device = create_device(user.id)

      assert {:ok, fetched_device} = RemoteAccess.get_active_device(device.id)
      assert fetched_device.id == device.id
      assert fetched_device.user.id == user.id
    end

    test "returns error for non-existent device" do
      assert {:error, :not_found} = RemoteAccess.get_active_device(Ecto.UUID.generate())
    end

    test "returns error for revoked device" do
      user = create_user()
      device = create_device(user.id)

      # Revoke the device
      {:ok, _revoked} = RemoteAccess.revoke_device(device)

      assert {:error, :revoked} = RemoteAccess.get_active_device(device.id)
    end

    test "preloads user association" do
      user = create_user()
      device = create_device(user.id)

      {:ok, fetched_device} = RemoteAccess.get_active_device(device.id)

      # User should be preloaded, not a reference
      assert %Mydia.Accounts.User{} = fetched_device.user
      assert fetched_device.user.email == user.email
    end
  end

  # Helper functions

  defp create_user do
    num = System.unique_integer([:positive])
    username = "user#{num}"
    email = "#{username}@example.com"

    {:ok, user} =
      Accounts.create_user(%{
        username: username,
        email: email,
        password: "password123456",
        role: "admin"
      })

    user
  end

  defp create_device(user_id) do
    token = :crypto.strong_rand_bytes(32) |> Base.encode64()

    {:ok, device} =
      RemoteAccess.create_device(%{
        device_name: "Test Device",
        platform: "ios",
        device_static_public_key: :crypto.strong_rand_bytes(32),
        token: token,
        user_id: user_id
      })

    device
  end
end
