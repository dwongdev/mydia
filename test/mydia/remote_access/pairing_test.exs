defmodule Mydia.RemoteAccess.PairingTest do
  use Mydia.DataCase

  alias Mydia.RemoteAccess
  alias Mydia.RemoteAccess.Pairing
  alias Mydia.Accounts

  describe "start_reconnect_handshake/0" do
    test "returns handshake state when keypair is configured" do
      # Initialize the keypair first
      {:ok, _config} = RemoteAccess.initialize_keypair()

      # Start handshake
      assert {:ok, handshake_state} = Pairing.start_reconnect_handshake()
      assert is_reference(handshake_state)
    end

    test "returns error when keypair is not configured" do
      # Don't initialize keypair
      assert {:error, :not_configured} = Pairing.start_reconnect_handshake()
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

      # Generate device keypair
      {device_public_key, _device_private_key} = Mydia.Crypto.Noise.generate_keypair()

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
      {random_key, _} = Mydia.Crypto.Noise.generate_keypair()
      assert {:error, :device_not_found} = Pairing.verify_device_key(random_key)
    end

    test "returns error for revoked device", %{
      device: device,
      device_public_key: device_public_key
    } do
      # Revoke the device
      {:ok, _revoked} = RemoteAccess.revoke_device(device)

      # Verify should fail
      assert {:error, :device_revoked} = Pairing.verify_device_key(device_public_key)
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
      {device_public_key, _device_private_key} = Mydia.Crypto.Noise.generate_keypair()

      # Create a paired device
      {:ok, device} =
        RemoteAccess.create_device(%{
          device_name: "Test Device",
          platform: "iOS",
          device_static_public_key: device_public_key,
          token: "test-token-#{System.unique_integer()}",
          user_id: user.id
        })

      # Create a mock handshake state (just a reference for testing)
      handshake_state = make_ref()

      %{device: device, handshake_state: handshake_state}
    end

    test "updates last_seen_at and generates token", %{
      device: device,
      handshake_state: handshake_state
    } do
      old_last_seen = device.last_seen_at

      assert {:ok, updated_device, token, returned_state} =
               Pairing.complete_reconnection(device, handshake_state)

      # Check that last_seen_at was updated
      refute updated_device.last_seen_at == old_last_seen
      assert DateTime.compare(updated_device.last_seen_at, DateTime.utc_now()) in [:lt, :eq]

      # Check that a token was generated
      assert is_binary(token)
      assert byte_size(token) > 0

      # Check that handshake state is returned
      assert returned_state == handshake_state
    end
  end

  describe "full handshake flow" do
    setup do
      # Initialize server keypair
      {:ok, _config} = RemoteAccess.initialize_keypair()

      # Create a user
      {:ok, user} =
        Accounts.create_user(%{
          username: "testuser",
          email: "test@example.com",
          password: "password123",
          display_name: "Test User"
        })

      # Generate device keypair
      {device_public_key, device_private_key} = Mydia.Crypto.Noise.generate_keypair()

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

    test "completes full Noise_IK handshake", %{device_keypair: device_keypair} do
      # Server: Start handshake
      {:ok, server_handshake} = Pairing.start_reconnect_handshake()

      # Client: Initialize IK handshake as initiator
      # Client needs to know server's public key
      server_public_key = RemoteAccess.get_public_key()
      protocol_name = "Noise_IK_25519_ChaChaPoly_BLAKE2b"
      client_keys = %{s: device_keypair, rs: server_public_key}
      client_handshake = Decibel.new(protocol_name, :ini, client_keys)

      # Client: Send first message (-> e, es, s, ss)
      client_message = Decibel.handshake_encrypt(client_handshake, <<>>)
      client_message_bin = IO.iodata_to_binary(client_message)

      # Server: Process client message and verify device
      assert {:ok, server_handshake_final, client_static_key, server_response, device} =
               Pairing.process_client_message(server_handshake, client_message_bin)

      # Verify we got the right device
      assert device.device_static_public_key == elem(device_keypair, 0)
      assert client_static_key == elem(device_keypair, 0)

      # Client: Process server response (<- e, ee, se)
      _payload = Decibel.handshake_decrypt(client_handshake, server_response)

      # Verify handshake is complete
      assert Decibel.is_handshake_complete?(client_handshake)
      assert Decibel.is_handshake_complete?(server_handshake_final)

      # Server: Complete reconnection
      assert {:ok, updated_device, token, _final_state} =
               Pairing.complete_reconnection(device, server_handshake_final)

      assert updated_device.id == device.id
      assert is_binary(token)

      # At this point, both parties have established a secure channel
      # and can use the handshake states for encrypted communication
    end
  end

  describe "start_pairing_handshake/0" do
    test "returns handshake state when keypair is configured" do
      # Initialize the keypair first
      {:ok, _config} = RemoteAccess.initialize_keypair()

      # Start pairing handshake
      assert {:ok, handshake_state} = Pairing.start_pairing_handshake()
      assert is_reference(handshake_state)
    end

    test "returns error when keypair is not configured" do
      # Don't initialize keypair
      assert {:error, :not_configured} = Pairing.start_pairing_handshake()
    end
  end

  describe "process_pairing_message/2" do
    setup do
      # Initialize server keypair
      {:ok, _config} = RemoteAccess.initialize_keypair()
      %{}
    end

    test "successfully processes client NK handshake message" do
      # Server: Start NK handshake
      {:ok, server_handshake} = Pairing.start_pairing_handshake()

      # Client: Initialize NK handshake as initiator
      server_public_key = RemoteAccess.get_public_key()
      protocol_name = "Noise_NK_25519_ChaChaPoly_BLAKE2b"
      client_keys = %{rs: server_public_key}
      client_handshake = Decibel.new(protocol_name, :ini, client_keys)

      # Client: Send first message (-> e, es)
      client_message = Decibel.handshake_encrypt(client_handshake, <<>>)
      client_message_bin = IO.iodata_to_binary(client_message)

      # Server: Process client message
      assert {:ok, _server_handshake_final, server_response} =
               Pairing.process_pairing_message(server_handshake, client_message_bin)

      # Verify we got a response
      assert is_binary(server_response)
      assert byte_size(server_response) > 0
    end

    test "returns error for invalid handshake message" do
      # Server: Start NK handshake
      {:ok, server_handshake} = Pairing.start_pairing_handshake()

      # Send garbage data
      invalid_message = :crypto.strong_rand_bytes(64)

      # Should fail
      assert {:error, :handshake_failed} =
               Pairing.process_pairing_message(server_handshake, invalid_message)
    end
  end

  describe "complete_pairing/3" do
    setup do
      # Initialize server keypair
      {:ok, _config} = RemoteAccess.initialize_keypair()

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

      # Create a mock handshake state
      handshake_state = make_ref()

      %{user: user, claim: claim, handshake_state: handshake_state}
    end

    test "successfully completes pairing with valid claim code", %{
      claim: claim,
      handshake_state: handshake_state
    } do
      device_attrs = %{
        device_name: "iPhone 15",
        platform: "iOS"
      }

      assert {:ok, device, media_token, {device_public_key, device_private_key}, returned_state} =
               Pairing.complete_pairing(claim.code, device_attrs, handshake_state)

      # Verify device was created
      assert device.device_name == "iPhone 15"
      assert device.platform == "iOS"
      assert device.user_id == claim.user_id

      # Verify keypair was generated
      assert is_binary(device_public_key)
      assert byte_size(device_public_key) == 32
      assert is_binary(device_private_key)
      assert byte_size(device_private_key) == 32

      # Verify token was generated
      assert is_binary(media_token)
      assert byte_size(media_token) > 0

      # Verify handshake state is returned
      assert returned_state == handshake_state

      # Verify claim code was consumed
      consumed_claim = RemoteAccess.get_claim_by_code(claim.code)
      assert consumed_claim.used_at != nil
      assert consumed_claim.device_id == device.id
    end

    test "fails with invalid claim code", %{handshake_state: handshake_state} do
      device_attrs = %{
        device_name: "iPhone 15",
        platform: "iOS"
      }

      assert {:error, :not_found} =
               Pairing.complete_pairing("INVALID-CODE", device_attrs, handshake_state)
    end

    test "fails with expired claim code", %{claim: claim, handshake_state: handshake_state} do
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
               Pairing.complete_pairing(claim.code, device_attrs, handshake_state)
    end

    test "fails with already used claim code", %{
      claim: claim,
      user: user,
      handshake_state: handshake_state
    } do
      # Create a device and consume the claim
      {device_public_key, _} = Mydia.Crypto.Noise.generate_keypair()

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
               Pairing.complete_pairing(claim.code, device_attrs, handshake_state)
    end
  end

  describe "full NK pairing flow" do
    setup do
      # Initialize server keypair
      {:ok, _config} = RemoteAccess.initialize_keypair()

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

    test "completes full Noise_NK pairing handshake", %{claim: claim} do
      # Server: Start NK handshake
      {:ok, server_handshake} = Pairing.start_pairing_handshake()

      # Client: Initialize NK handshake as initiator
      server_public_key = RemoteAccess.get_public_key()
      protocol_name = "Noise_NK_25519_ChaChaPoly_BLAKE2b"
      client_keys = %{rs: server_public_key}
      client_handshake = Decibel.new(protocol_name, :ini, client_keys)

      # Client: Send first message (-> e, es)
      client_message = Decibel.handshake_encrypt(client_handshake, <<>>)
      client_message_bin = IO.iodata_to_binary(client_message)

      # Server: Process client message
      assert {:ok, server_handshake_final, server_response} =
               Pairing.process_pairing_message(server_handshake, client_message_bin)

      # Client: Process server response (<- e, ee)
      _payload = Decibel.handshake_decrypt(client_handshake, server_response)

      # Verify handshake is complete
      assert Decibel.is_handshake_complete?(client_handshake)
      assert Decibel.is_handshake_complete?(server_handshake_final)

      # Server: Complete pairing with claim code
      device_attrs = %{
        device_name: "Test Phone",
        platform: "iOS"
      }

      assert {:ok, device, media_token, {device_public_key, device_private_key}, _final_state} =
               Pairing.complete_pairing(claim.code, device_attrs, server_handshake_final)

      # Verify device was created
      assert device.device_name == "Test Phone"
      assert device.platform == "iOS"
      assert device.user_id == claim.user_id

      # Verify keypair was generated
      assert byte_size(device_public_key) == 32
      assert byte_size(device_private_key) == 32

      # Verify token was generated
      assert is_binary(media_token)

      # At this point, the device keypair can be sent to the client
      # over the encrypted Noise channel
    end
  end
end
