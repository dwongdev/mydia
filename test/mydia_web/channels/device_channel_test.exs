defmodule MydiaWeb.DeviceChannelTest do
  use MydiaWeb.ChannelCase

  alias Mydia.RemoteAccess
  alias Mydia.Accounts

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
      device_keypair: {device_public_key, device_private_key},
      user: user
    }
  end

  describe "join device:reconnect" do
    test "successfully joins the channel", %{device_keypair: _device_keypair} do
      assert {:ok, _reply, socket} =
               socket(MydiaWeb.UserSocket, "user_id", %{})
               |> subscribe_and_join(MydiaWeb.DeviceChannel, "device:reconnect", %{})

      # Verify handshake state is assigned
      assert socket.assigns.handshake_state
      assert is_reference(socket.assigns.handshake_state)
    end

    test "rejects invalid topic" do
      assert {:error, %{reason: "invalid_topic"}} =
               socket(MydiaWeb.UserSocket, "user_id", %{})
               |> subscribe_and_join(MydiaWeb.DeviceChannel, "device:invalid", %{})
    end
  end

  describe "handshake_init" do
    test "successfully completes handshake with valid device", %{device_keypair: device_keypair} do
      # Join the channel
      {:ok, _reply, socket} =
        socket(MydiaWeb.UserSocket, "user_id", %{})
        |> subscribe_and_join(MydiaWeb.DeviceChannel, "device:reconnect", %{})

      # Client: Initialize IK handshake as initiator
      server_public_key = RemoteAccess.get_public_key()
      protocol_name = "Noise_IK_25519_ChaChaPoly_BLAKE2b"
      client_keys = %{s: device_keypair, rs: server_public_key}
      client_handshake = Decibel.new(protocol_name, :ini, client_keys)

      # Client: Generate first message
      client_message = Decibel.handshake_encrypt(client_handshake, <<>>)
      client_message_bin = IO.iodata_to_binary(client_message)

      # Send handshake_init message
      ref = push(socket, "handshake_init", %{"message" => Base.encode64(client_message_bin)})

      # Should receive successful reply with server response and token
      assert_reply ref, :ok, %{message: server_response_b64, token: token, device_id: device_id}

      # Verify we got a valid response
      assert is_binary(server_response_b64)
      assert is_binary(token)
      assert is_binary(device_id)

      # Verify server response can be decoded
      assert {:ok, _server_response} = Base.decode64(server_response_b64)
    end

    test "rejects handshake with unknown device key" do
      # Join the channel
      {:ok, _reply, socket} =
        socket(MydiaWeb.UserSocket, "user_id", %{})
        |> subscribe_and_join(MydiaWeb.DeviceChannel, "device:reconnect", %{})

      # Client: Use a different keypair not in the database
      {unknown_public, unknown_private} = Mydia.Crypto.Noise.generate_keypair()
      unknown_keypair = {unknown_public, unknown_private}

      # Client: Initialize handshake with unknown key
      server_public_key = RemoteAccess.get_public_key()
      protocol_name = "Noise_IK_25519_ChaChaPoly_BLAKE2b"
      client_keys = %{s: unknown_keypair, rs: server_public_key}
      client_handshake = Decibel.new(protocol_name, :ini, client_keys)

      # Client: Generate first message
      client_message = Decibel.handshake_encrypt(client_handshake, <<>>)
      client_message_bin = IO.iodata_to_binary(client_message)

      # Send handshake_init message
      ref = push(socket, "handshake_init", %{"message" => Base.encode64(client_message_bin)})

      # Should receive error
      assert_reply ref, :error, %{reason: "device_not_found"}
    end

    test "rejects handshake with revoked device", %{
      device: device,
      device_keypair: device_keypair
    } do
      # Revoke the device
      {:ok, _revoked} = RemoteAccess.revoke_device(device)

      # Join the channel
      {:ok, _reply, socket} =
        socket(MydiaWeb.UserSocket, "user_id", %{})
        |> subscribe_and_join(MydiaWeb.DeviceChannel, "device:reconnect", %{})

      # Client: Initialize handshake
      server_public_key = RemoteAccess.get_public_key()
      protocol_name = "Noise_IK_25519_ChaChaPoly_BLAKE2b"
      client_keys = %{s: device_keypair, rs: server_public_key}
      client_handshake = Decibel.new(protocol_name, :ini, client_keys)

      # Client: Generate first message
      client_message = Decibel.handshake_encrypt(client_handshake, <<>>)
      client_message_bin = IO.iodata_to_binary(client_message)

      # Send handshake_init message
      ref = push(socket, "handshake_init", %{"message" => Base.encode64(client_message_bin)})

      # Should receive error
      assert_reply ref, :error, %{reason: "device_revoked"}
    end

    test "rejects invalid base64 message" do
      # Join the channel
      {:ok, _reply, socket} =
        socket(MydiaWeb.UserSocket, "user_id", %{})
        |> subscribe_and_join(MydiaWeb.DeviceChannel, "device:reconnect", %{})

      # Send invalid base64
      ref = push(socket, "handshake_init", %{"message" => "not-valid-base64!!!"})

      # Should receive error
      assert_reply ref, :error, %{reason: _reason}
    end
  end

  describe "device updates" do
    test "updates last_seen_at after successful handshake", %{
      device: device,
      device_keypair: device_keypair
    } do
      old_last_seen = device.last_seen_at

      # Join the channel
      {:ok, _reply, socket} =
        socket(MydiaWeb.UserSocket, "user_id", %{})
        |> subscribe_and_join(MydiaWeb.DeviceChannel, "device:reconnect", %{})

      # Complete handshake
      server_public_key = RemoteAccess.get_public_key()
      protocol_name = "Noise_IK_25519_ChaChaPoly_BLAKE2b"
      client_keys = %{s: device_keypair, rs: server_public_key}
      client_handshake = Decibel.new(protocol_name, :ini, client_keys)
      client_message = Decibel.handshake_encrypt(client_handshake, <<>>)
      client_message_bin = IO.iodata_to_binary(client_message)

      ref = push(socket, "handshake_init", %{"message" => Base.encode64(client_message_bin)})
      assert_reply ref, :ok, %{device_id: device_id}

      # Reload device and check last_seen_at was updated
      updated_device = RemoteAccess.get_device!(device_id)
      refute updated_device.last_seen_at == old_last_seen
      assert DateTime.compare(updated_device.last_seen_at, DateTime.utc_now()) in [:lt, :eq]
    end
  end

  describe "join device:pair" do
    test "successfully joins the pairing channel", %{} do
      assert {:ok, _reply, socket} =
               socket(MydiaWeb.UserSocket, "user_id", %{})
               |> subscribe_and_join(MydiaWeb.DeviceChannel, "device:pair", %{})

      # Verify handshake state is assigned
      assert socket.assigns.handshake_state
      assert is_reference(socket.assigns.handshake_state)
    end
  end

  describe "pairing_handshake" do
    test "successfully completes NK handshake", %{} do
      # Join the pairing channel
      {:ok, _reply, socket} =
        socket(MydiaWeb.UserSocket, "user_id", %{})
        |> subscribe_and_join(MydiaWeb.DeviceChannel, "device:pair", %{})

      # Client: Initialize NK handshake as initiator
      server_public_key = RemoteAccess.get_public_key()
      protocol_name = "Noise_NK_25519_ChaChaPoly_BLAKE2b"
      client_keys = %{rs: server_public_key}
      client_handshake = Decibel.new(protocol_name, :ini, client_keys)

      # Client: Generate first message
      client_message = Decibel.handshake_encrypt(client_handshake, <<>>)
      client_message_bin = IO.iodata_to_binary(client_message)

      # Send pairing_handshake message
      ref = push(socket, "pairing_handshake", %{"message" => Base.encode64(client_message_bin)})

      # Should receive successful reply with server response
      assert_reply ref, :ok, %{message: server_response_b64}

      # Verify we got a valid response
      assert is_binary(server_response_b64)
      assert {:ok, server_response} = Base.decode64(server_response_b64)

      # Client: Process server response
      _payload = Decibel.handshake_decrypt(client_handshake, server_response)

      # Verify handshake is complete
      assert Decibel.is_handshake_complete?(client_handshake)
    end

    test "rejects invalid handshake message", %{} do
      # Join the pairing channel
      {:ok, _reply, socket} =
        socket(MydiaWeb.UserSocket, "user_id", %{})
        |> subscribe_and_join(MydiaWeb.DeviceChannel, "device:pair", %{})

      # Send invalid message
      ref =
        push(socket, "pairing_handshake", %{
          "message" => Base.encode64(:crypto.strong_rand_bytes(64))
        })

      # Should receive error
      assert_reply ref, :error, %{reason: "handshake_failed"}
    end

    test "rejects invalid base64 message", %{} do
      # Join the pairing channel
      {:ok, _reply, socket} =
        socket(MydiaWeb.UserSocket, "user_id", %{})
        |> subscribe_and_join(MydiaWeb.DeviceChannel, "device:pair", %{})

      # Send invalid base64
      ref = push(socket, "pairing_handshake", %{"message" => "not-valid-base64!!!"})

      # Should receive error
      assert_reply ref, :error, %{reason: "invalid_message"}
    end
  end

  describe "claim_code" do
    setup %{user: user} do
      # Generate a claim code for the existing user
      {:ok, claim} = RemoteAccess.generate_claim_code(user.id)

      %{claim: claim}
    end

    test "successfully completes pairing with valid claim code", %{claim: claim} do
      # Join the pairing channel
      {:ok, _reply, socket} =
        socket(MydiaWeb.UserSocket, "user_id", %{})
        |> subscribe_and_join(MydiaWeb.DeviceChannel, "device:pair", %{})

      # Complete NK handshake first
      server_public_key = RemoteAccess.get_public_key()
      protocol_name = "Noise_NK_25519_ChaChaPoly_BLAKE2b"
      client_keys = %{rs: server_public_key}
      client_handshake = Decibel.new(protocol_name, :ini, client_keys)
      client_message = Decibel.handshake_encrypt(client_handshake, <<>>)
      client_message_bin = IO.iodata_to_binary(client_message)

      ref = push(socket, "pairing_handshake", %{"message" => Base.encode64(client_message_bin)})
      assert_reply ref, :ok, %{message: server_response_b64}

      {:ok, server_response} = Base.decode64(server_response_b64)
      _payload = Decibel.handshake_decrypt(client_handshake, server_response)

      # Now send claim code
      ref =
        push(socket, "claim_code", %{
          "code" => claim.code,
          "device_name" => "Test Phone",
          "platform" => "iOS"
        })

      # Should receive pairing complete with device info and keypair
      assert_reply ref, :ok, %{
        device_id: device_id,
        media_token: media_token,
        device_public_key: device_public_key_b64,
        device_private_key: device_private_key_b64
      }

      # Verify response structure
      assert is_binary(device_id)
      assert is_binary(media_token)
      assert {:ok, device_public_key} = Base.decode64(device_public_key_b64)
      assert {:ok, device_private_key} = Base.decode64(device_private_key_b64)
      assert byte_size(device_public_key) == 32
      assert byte_size(device_private_key) == 32

      # Verify device was created in database
      device = RemoteAccess.get_device!(device_id)
      assert device.device_name == "Test Phone"
      assert device.platform == "iOS"
      assert device.user_id == claim.user_id

      # Verify claim code was consumed
      consumed_claim = RemoteAccess.get_claim_by_code(claim.code)
      assert consumed_claim.used_at != nil
      assert consumed_claim.device_id == device_id
    end

    test "rejects claim code before handshake completion", %{claim: claim} do
      # Join the pairing channel
      {:ok, _reply, socket} =
        socket(MydiaWeb.UserSocket, "user_id", %{})
        |> subscribe_and_join(MydiaWeb.DeviceChannel, "device:pair", %{})

      # Try to send claim code without completing handshake
      ref =
        push(socket, "claim_code", %{
          "code" => claim.code,
          "device_name" => "Test Phone",
          "platform" => "iOS"
        })

      # Should receive error
      assert_reply ref, :error, %{reason: "handshake_incomplete"}
    end

    test "rejects invalid claim code" do
      # Join and complete handshake
      {:ok, _reply, socket} =
        socket(MydiaWeb.UserSocket, "user_id", %{})
        |> subscribe_and_join(MydiaWeb.DeviceChannel, "device:pair", %{})

      server_public_key = RemoteAccess.get_public_key()
      protocol_name = "Noise_NK_25519_ChaChaPoly_BLAKE2b"
      client_keys = %{rs: server_public_key}
      client_handshake = Decibel.new(protocol_name, :ini, client_keys)
      client_message = Decibel.handshake_encrypt(client_handshake, <<>>)
      client_message_bin = IO.iodata_to_binary(client_message)

      ref = push(socket, "pairing_handshake", %{"message" => Base.encode64(client_message_bin)})
      assert_reply ref, :ok, %{message: server_response_b64}

      {:ok, server_response} = Base.decode64(server_response_b64)
      _payload = Decibel.handshake_decrypt(client_handshake, server_response)

      # Send invalid claim code
      ref =
        push(socket, "claim_code", %{
          "code" => "INVALID-CODE",
          "device_name" => "Test Phone",
          "platform" => "iOS"
        })

      # Should receive error
      assert_reply ref, :error, %{reason: "invalid_claim_code"}
    end

    test "rejects expired claim code", %{claim: claim} do
      # Expire the claim
      past_time = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:second)

      claim
      |> Ecto.Changeset.change(expires_at: past_time)
      |> Mydia.Repo.update!()

      # Join and complete handshake
      {:ok, _reply, socket} =
        socket(MydiaWeb.UserSocket, "user_id", %{})
        |> subscribe_and_join(MydiaWeb.DeviceChannel, "device:pair", %{})

      server_public_key = RemoteAccess.get_public_key()
      protocol_name = "Noise_NK_25519_ChaChaPoly_BLAKE2b"
      client_keys = %{rs: server_public_key}
      client_handshake = Decibel.new(protocol_name, :ini, client_keys)
      client_message = Decibel.handshake_encrypt(client_handshake, <<>>)
      client_message_bin = IO.iodata_to_binary(client_message)

      ref = push(socket, "pairing_handshake", %{"message" => Base.encode64(client_message_bin)})
      assert_reply ref, :ok, %{message: server_response_b64}

      {:ok, server_response} = Base.decode64(server_response_b64)
      _payload = Decibel.handshake_decrypt(client_handshake, server_response)

      # Send expired claim code
      ref =
        push(socket, "claim_code", %{
          "code" => claim.code,
          "device_name" => "Test Phone",
          "platform" => "iOS"
        })

      # Should receive error
      assert_reply ref, :error, %{reason: "claim_code_expired"}
    end
  end
end
