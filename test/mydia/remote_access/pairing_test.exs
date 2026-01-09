defmodule Mydia.RemoteAccess.PairingTest do
  use Mydia.DataCase

  alias Mydia.RemoteAccess
  alias Mydia.RemoteAccess.Pairing
  alias Mydia.Accounts
  alias Mydia.Crypto

  describe "start_reconnect_handshake/0" do
    test "returns server keypair for session" do
      # Start handshake - this generates an ephemeral keypair for the session
      assert {:ok, public_key, private_key} = Pairing.start_reconnect_handshake()
      assert byte_size(public_key) == 32
      assert byte_size(private_key) == 32
    end
  end

  describe "verify_device_key/1" do
    setup do
      # Create a user
      {:ok, user} =
        Accounts.create_user(%{
          username: "testuser",
          email: "test@example.com",
          password: "password123",
          display_name: "Test User"
        })

      # Generate device keypair using new Crypto module
      {device_public_key, _device_private_key} = Crypto.generate_keypair()

      # Create a paired device
      {:ok, device} =
        RemoteAccess.create_device(%{
          device_name: "Test Device",
          platform: "iOS",
          device_static_public_key: device_public_key,
          token: "test-token-#{System.unique_integer()}",
          user_id: user.id
        })

      %{device: device, device_public_key: device_public_key, user: user}
    end

    test "returns ok for valid device key", %{device_public_key: device_public_key} do
      assert {:ok, device} = Pairing.verify_device_key(device_public_key)
      assert device.device_static_public_key == device_public_key
    end

    test "returns error for non-existent device key" do
      {random_key, _} = Crypto.generate_keypair()
      assert {:error, :device_not_found} = Pairing.verify_device_key(random_key)
    end

    test "returns device_not_found for revoked device (prevents enumeration)", %{
      device: device,
      device_public_key: device_public_key
    } do
      # Revoke the device
      {:ok, _revoked} = RemoteAccess.revoke_device(device)

      # Verify should return same error as not found to prevent device enumeration
      # An attacker should not be able to distinguish between
      # "device doesn't exist" and "device exists but is revoked"
      assert {:error, :device_not_found} = Pairing.verify_device_key(device_public_key)
    end
  end

  describe "process_client_message/2 (reconnection)" do
    setup do
      # Create a user
      {:ok, user} =
        Accounts.create_user(%{
          username: "testuser",
          email: "test@example.com",
          password: "password123",
          display_name: "Test User"
        })

      # Generate device keypair
      {device_public_key, device_private_key} = Crypto.generate_keypair()

      # Create a paired device
      {:ok, device} =
        RemoteAccess.create_device(%{
          device_name: "Test Device",
          platform: "iOS",
          device_static_public_key: device_public_key,
          token: "test-token-#{System.unique_integer()}",
          user_id: user.id
        })

      %{
        device: device,
        device_public_key: device_public_key,
        device_private_key: device_private_key,
        user: user
      }
    end

    test "successfully derives session key for valid device", %{
      device_public_key: device_public_key
    } do
      # Server generates ephemeral keypair
      {:ok, server_public_key, server_private_key} = Pairing.start_reconnect_handshake()

      # Process client's public key (the device's stored key)
      assert {:ok, session_key, device} =
               Pairing.process_client_message(server_private_key, device_public_key)

      # Verify we got the right device
      assert device.device_static_public_key == device_public_key

      # Verify session key was derived
      assert byte_size(session_key) == 32
    end

    test "accepts base64-encoded client public key", %{device_public_key: device_public_key} do
      # Server generates ephemeral keypair
      {:ok, _server_public_key, server_private_key} = Pairing.start_reconnect_handshake()

      # Encode the device public key as base64 (as client would send it)
      encoded_key = Base.encode64(device_public_key)

      # Process client's base64-encoded public key
      assert {:ok, session_key, device} =
               Pairing.process_client_message(server_private_key, encoded_key)

      # Verify we got the right device
      assert device.device_static_public_key == device_public_key
      assert byte_size(session_key) == 32
    end

    test "returns error for non-existent device" do
      # Server generates ephemeral keypair
      {:ok, _server_public_key, server_private_key} = Pairing.start_reconnect_handshake()

      # Generate a random key that's not in the database
      {random_key, _} = Crypto.generate_keypair()

      # Should fail
      assert {:error, :device_not_found} =
               Pairing.process_client_message(server_private_key, random_key)
    end

    test "returns error for invalid key format" do
      # Server generates ephemeral keypair
      {:ok, _server_public_key, server_private_key} = Pairing.start_reconnect_handshake()

      # Send garbage data that can't be decoded
      assert {:error, :invalid_key} =
               Pairing.process_client_message(server_private_key, "not-valid-base64!!!")
    end
  end

  describe "complete_reconnection/2" do
    setup do
      # Create a user
      {:ok, user} =
        Accounts.create_user(%{
          username: "testuser",
          email: "test@example.com",
          password: "password123",
          display_name: "Test User"
        })

      # Generate device keypair
      {device_public_key, _device_private_key} = Crypto.generate_keypair()

      # Create a paired device
      {:ok, device} =
        RemoteAccess.create_device(%{
          device_name: "Test Device",
          platform: "iOS",
          device_static_public_key: device_public_key,
          token: "test-token-#{System.unique_integer()}",
          user_id: user.id
        })

      # Generate a session key (as would be derived from ECDH)
      session_key = :crypto.strong_rand_bytes(32)

      %{device: device, session_key: session_key}
    end

    test "updates last_seen_at and generates tokens", %{
      device: device,
      session_key: session_key
    } do
      old_last_seen = device.last_seen_at

      assert {:ok, updated_device, media_token, access_token, returned_key} =
               Pairing.complete_reconnection(device, session_key)

      # Check that last_seen_at was updated
      refute updated_device.last_seen_at == old_last_seen
      assert DateTime.compare(updated_device.last_seen_at, DateTime.utc_now()) in [:lt, :eq]

      # Check that tokens were generated
      assert is_binary(media_token)
      assert byte_size(media_token) > 0
      assert is_binary(access_token)
      assert byte_size(access_token) > 0

      # Check that session key is returned
      assert returned_key == session_key
    end
  end

  describe "full reconnection flow" do
    setup do
      # Create a user
      {:ok, user} =
        Accounts.create_user(%{
          username: "testuser",
          email: "test@example.com",
          password: "password123",
          display_name: "Test User"
        })

      # Generate device keypair
      {device_public_key, device_private_key} = Crypto.generate_keypair()

      # Create a paired device
      {:ok, device} =
        RemoteAccess.create_device(%{
          device_name: "Test Device",
          platform: "iOS",
          device_static_public_key: device_public_key,
          token: "test-token-#{System.unique_integer()}",
          user_id: user.id
        })

      %{
        device: device,
        device_keypair: {device_public_key, device_private_key}
      }
    end

    test "completes full X25519 key exchange for reconnection", %{
      device_keypair: {device_public_key, device_private_key}
    } do
      # Step 1: Server generates ephemeral keypair
      {:ok, server_public_key, server_private_key} = Pairing.start_reconnect_handshake()

      # Step 2: Client sends its stored static public key to server
      #         Server derives session key and verifies device
      assert {:ok, server_session_key, device} =
               Pairing.process_client_message(server_private_key, device_public_key)

      # Verify we got the right device
      assert device.device_static_public_key == device_public_key

      # Step 3: Client receives server's ephemeral public key and derives same session key
      client_session_key = Crypto.derive_session_key(device_private_key, server_public_key)

      # Both parties should have the same session key
      assert server_session_key == client_session_key

      # Step 4: Server completes reconnection
      assert {:ok, updated_device, media_token, access_token, _session_key} =
               Pairing.complete_reconnection(device, server_session_key)

      assert updated_device.id == device.id
      assert is_binary(media_token)
      assert is_binary(access_token)

      # Step 5: Verify encryption works with shared session key
      # Server encrypts a message
      message = "Hello from server!"
      encrypted = Crypto.encrypt(message, server_session_key)

      # Client decrypts the message
      {:ok, decrypted} =
        Crypto.decrypt(
          encrypted.ciphertext,
          encrypted.nonce,
          encrypted.mac,
          client_session_key
        )

      assert decrypted == message
    end
  end

  describe "start_pairing_handshake/0" do
    test "returns server keypair for pairing session" do
      # Start pairing handshake - this generates an ephemeral keypair
      assert {:ok, public_key, private_key} = Pairing.start_pairing_handshake()
      assert byte_size(public_key) == 32
      assert byte_size(private_key) == 32
    end
  end

  describe "process_pairing_message/2" do
    test "successfully derives session key from client's public key" do
      # Server generates ephemeral keypair
      {:ok, server_public_key, server_private_key} = Pairing.start_pairing_handshake()

      # Client generates ephemeral keypair
      {client_public_key, client_private_key} = Crypto.generate_keypair()

      # Server processes client's public key
      assert {:ok, server_session_key} =
               Pairing.process_pairing_message(server_private_key, client_public_key)

      assert byte_size(server_session_key) == 32

      # Client derives the same session key
      client_session_key = Crypto.derive_session_key(client_private_key, server_public_key)

      # Both should be equal
      assert server_session_key == client_session_key
    end

    test "accepts base64-encoded client public key" do
      # Server generates ephemeral keypair
      {:ok, _server_public_key, server_private_key} = Pairing.start_pairing_handshake()

      # Client generates ephemeral keypair
      {client_public_key, _client_private_key} = Crypto.generate_keypair()

      # Encode the client public key as base64
      encoded_key = Base.encode64(client_public_key)

      # Server processes client's base64-encoded public key
      assert {:ok, session_key} =
               Pairing.process_pairing_message(server_private_key, encoded_key)

      assert byte_size(session_key) == 32
    end

    test "returns error for invalid key format" do
      # Server generates ephemeral keypair
      {:ok, _server_public_key, server_private_key} = Pairing.start_pairing_handshake()

      # Send garbage data that can't be decoded
      assert {:error, :invalid_key} =
               Pairing.process_pairing_message(server_private_key, "not-valid-base64!!!")
    end
  end

  # These tests require the Relay service to be running
  describe "complete_pairing/4" do
    @describetag :external
    setup do
      # Create a user
      {:ok, user} =
        Accounts.create_user(%{
          username: "pairuser",
          email: "pair@example.com",
          password: "password123",
          display_name: "Pair User"
        })

      # Generate a claim code
      {:ok, claim} = RemoteAccess.generate_claim_code(user.id)

      # Generate a session key (as would be derived from ECDH)
      session_key = :crypto.strong_rand_bytes(32)

      # Generate client static keypair (as client would do)
      {client_public_key, _client_private_key} = Crypto.generate_keypair()

      %{
        user: user,
        claim: claim,
        session_key: session_key,
        client_public_key: client_public_key
      }
    end

    test "successfully completes pairing with valid claim code", %{
      claim: claim,
      session_key: session_key,
      client_public_key: client_public_key
    } do
      device_attrs = %{
        device_name: "iPhone 15",
        platform: "iOS"
      }

      assert {:ok, device, media_token, returned_key} =
               Pairing.complete_pairing(claim.code, device_attrs, client_public_key, session_key)

      # Verify device was created
      assert device.device_name == "iPhone 15"
      assert device.platform == "iOS"
      assert device.user_id == claim.user_id

      # Verify device has the client's public key (not server-generated)
      assert device.device_static_public_key == client_public_key

      # Verify token was generated
      assert is_binary(media_token)
      assert byte_size(media_token) > 0

      # Verify session key is returned
      assert returned_key == session_key

      # Verify claim code was consumed
      consumed_claim = RemoteAccess.get_claim_by_code(claim.code)
      assert consumed_claim.used_at != nil
      assert consumed_claim.device_id == device.id
    end

    test "fails with invalid claim code", %{
      session_key: session_key,
      client_public_key: client_public_key
    } do
      device_attrs = %{
        device_name: "iPhone 15",
        platform: "iOS"
      }

      assert {:error, :not_found} =
               Pairing.complete_pairing(
                 "INVALID-CODE",
                 device_attrs,
                 client_public_key,
                 session_key
               )
    end

    test "fails with expired claim code", %{
      claim: claim,
      session_key: session_key,
      client_public_key: client_public_key
    } do
      # Manually expire the claim
      past_time = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:second)

      claim
      |> Ecto.Changeset.change(expires_at: past_time)
      |> Mydia.Repo.update!()

      device_attrs = %{
        device_name: "iPhone 15",
        platform: "iOS"
      }

      assert {:error, :expired} =
               Pairing.complete_pairing(claim.code, device_attrs, client_public_key, session_key)
    end

    test "fails with already used claim code", %{
      claim: claim,
      user: user,
      session_key: session_key,
      client_public_key: client_public_key
    } do
      # Create a device and consume the claim
      {device_public_key, _} = Crypto.generate_keypair()

      {:ok, device} =
        RemoteAccess.create_device(%{
          device_name: "First Device",
          platform: "iOS",
          device_static_public_key: device_public_key,
          token: "test-token-#{System.unique_integer()}",
          user_id: user.id
        })

      {:ok, _consumed_claim} = RemoteAccess.consume_claim_code(claim.code, device.id)

      # Try to use the same claim code again
      device_attrs = %{
        device_name: "Second Device",
        platform: "Android"
      }

      assert {:error, :already_used} =
               Pairing.complete_pairing(claim.code, device_attrs, client_public_key, session_key)
    end

    test "fails with invalid public key size", %{
      claim: claim,
      session_key: session_key
    } do
      device_attrs = %{
        device_name: "iPhone 15",
        platform: "iOS"
      }

      # Invalid key size (not 32 bytes)
      invalid_key = :crypto.strong_rand_bytes(16)

      assert {:error, :invalid_key} =
               Pairing.complete_pairing(claim.code, device_attrs, invalid_key, session_key)
    end
  end

  # This test requires the Relay service to be running
  describe "full X25519 pairing flow" do
    @describetag :external
    setup do
      # Create a user
      {:ok, user} =
        Accounts.create_user(%{
          username: "pairuser",
          email: "pair@example.com",
          password: "password123",
          display_name: "Pair User"
        })

      # Generate a claim code
      {:ok, claim} = RemoteAccess.generate_claim_code(user.id)

      %{user: user, claim: claim}
    end

    test "completes full X25519 pairing handshake with client-side key generation", %{
      claim: claim
    } do
      # Step 1: Server generates ephemeral keypair for session
      {:ok, server_public_key, server_private_key} = Pairing.start_pairing_handshake()

      # Step 2: Client generates ephemeral keypair for session
      {client_ephemeral_public, client_ephemeral_private} = Crypto.generate_keypair()

      # Step 3: Client sends ephemeral public key to server
      #         Server derives session key
      assert {:ok, server_session_key} =
               Pairing.process_pairing_message(server_private_key, client_ephemeral_public)

      # Step 4: Client receives server's public key and derives same session key
      client_session_key = Crypto.derive_session_key(client_ephemeral_private, server_public_key)

      # Both parties should have the same session key
      assert server_session_key == client_session_key

      # Step 5: Client generates STATIC keypair for device identification
      # This keypair is persistent and never leaves the client
      {client_static_public_key, _client_static_private_key} = Crypto.generate_keypair()

      # Step 6: Client sends claim_code with static public key
      device_attrs = %{
        device_name: "Test Phone",
        platform: "iOS"
      }

      assert {:ok, device, media_token, returned_session_key} =
               Pairing.complete_pairing(
                 claim.code,
                 device_attrs,
                 client_static_public_key,
                 server_session_key
               )

      # Verify device was created
      assert device.device_name == "Test Phone"
      assert device.platform == "iOS"
      assert device.user_id == claim.user_id

      # Verify the device has the CLIENT's static public key (not server-generated)
      assert device.device_static_public_key == client_static_public_key

      # Verify token was generated
      assert is_binary(media_token)

      # Verify session key is returned
      assert returned_session_key == server_session_key

      # The client's private key stays on the client device - never transmitted!
      # Server only stores the public key for reconnection verification
    end
  end
end
