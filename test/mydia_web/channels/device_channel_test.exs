defmodule MydiaWeb.DeviceChannelTest do
  use MydiaWeb.ChannelCase

  # These tests require relay connection for claim code generation
  @moduletag :requires_relay

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

    # Generate device keypair using the new Mydia.Crypto module
    {device_public_key, device_private_key} = Mydia.Crypto.generate_keypair()

    # Generate a device token (need to store it separately since it's a virtual field)
    device_token = "test-token-#{System.unique_integer()}"

    # Create a paired device
    {:ok, device} =
      RemoteAccess.create_device(%{
        device_name: "Test Device",
        platform: "iOS",
        device_static_public_key: device_public_key,
        token: device_token,
        user_id: user.id
      })

    %{
      device: device,
      device_token: device_token,
      device_keypair: {device_public_key, device_private_key},
      user: user
    }
  end

  describe "join device:reconnect" do
    test "successfully joins the channel", %{device_keypair: _device_keypair} do
      assert {:ok, _reply, socket} =
               socket(MydiaWeb.UserSocket, "user_id", %{})
               |> subscribe_and_join(MydiaWeb.DeviceChannel, "device:reconnect", %{})

      # Verify server keypair is assigned (new X25519 protocol)
      assert socket.assigns.server_public_key
      assert socket.assigns.server_private_key
      assert byte_size(socket.assigns.server_public_key) == 32
      assert byte_size(socket.assigns.server_private_key) == 32
    end

    test "rejects invalid topic" do
      assert {:error, %{reason: "invalid_topic"}} =
               socket(MydiaWeb.UserSocket, "user_id", %{})
               |> subscribe_and_join(MydiaWeb.DeviceChannel, "device:invalid", %{})
    end
  end

  describe "key_exchange (X25519)" do
    test "successfully completes key exchange with valid device", %{
      device: device,
      device_token: device_token,
      device_keypair: {device_public_key, _device_private_key}
    } do
      # Join the channel
      {:ok, _reply, socket} =
        socket(MydiaWeb.UserSocket, "user_id", %{})
        |> subscribe_and_join(MydiaWeb.DeviceChannel, "device:reconnect", %{})

      # Send key_exchange message with device's static public key and token
      ref =
        push(socket, "key_exchange", %{
          "client_public_key" => Base.encode64(device_public_key),
          "device_token" => device_token
        })

      # Should receive successful reply with server's public key and token
      # Note: Increased timeout to 500ms due to Argon2 token verification (~80ms)
      assert_reply ref,
                   :ok,
                   %{
                     server_public_key: server_public_key_b64,
                     token: token,
                     device_id: device_id
                   },
                   500

      # Verify we got valid response
      assert is_binary(server_public_key_b64)
      assert is_binary(token)
      assert device_id == device.id

      # Verify server public key can be decoded
      assert {:ok, server_public_key} = Base.decode64(server_public_key_b64)
      assert byte_size(server_public_key) == 32
    end

    test "rejects key exchange with unknown device key" do
      # Join the channel
      {:ok, _reply, socket} =
        socket(MydiaWeb.UserSocket, "user_id", %{})
        |> subscribe_and_join(MydiaWeb.DeviceChannel, "device:reconnect", %{})

      # Use a different keypair not in the database
      {unknown_public, _unknown_private} = Mydia.Crypto.generate_keypair()

      # Send key_exchange message with unknown key
      ref =
        push(socket, "key_exchange", %{
          "client_public_key" => Base.encode64(unknown_public),
          "device_token" => "fake-token"
        })

      # Should receive error
      assert_reply ref, :error, %{reason: "device_not_found"}
    end

    test "rejects key exchange with revoked device", %{
      device: device,
      device_token: device_token,
      device_keypair: {device_public_key, _device_private_key}
    } do
      # Revoke the device
      {:ok, _revoked} = RemoteAccess.revoke_device(device)

      # Join the channel
      {:ok, _reply, socket} =
        socket(MydiaWeb.UserSocket, "user_id", %{})
        |> subscribe_and_join(MydiaWeb.DeviceChannel, "device:reconnect", %{})

      # Send key_exchange message
      ref =
        push(socket, "key_exchange", %{
          "client_public_key" => Base.encode64(device_public_key),
          "device_token" => device_token
        })

      # Should receive error - returns "device_not_found" to prevent enumeration
      # (revoked devices return same error as non-existent for security)
      assert_reply ref, :error, %{reason: "device_not_found"}
    end

    test "rejects key exchange with invalid device token", %{
      device_keypair: {device_public_key, _device_private_key}
    } do
      # Join the channel
      {:ok, _reply, socket} =
        socket(MydiaWeb.UserSocket, "user_id", %{})
        |> subscribe_and_join(MydiaWeb.DeviceChannel, "device:reconnect", %{})

      # Send key_exchange message with wrong token
      ref =
        push(socket, "key_exchange", %{
          "client_public_key" => Base.encode64(device_public_key),
          "device_token" => "wrong-token"
        })

      # Should receive error
      # Note: Increased timeout due to Argon2 token verification (~80ms)
      assert_reply ref, :error, %{reason: "invalid_device_token"}, 500
    end
  end

  describe "deprecated handshake_init" do
    test "returns use_key_exchange error" do
      # Join the channel
      {:ok, _reply, socket} =
        socket(MydiaWeb.UserSocket, "user_id", %{})
        |> subscribe_and_join(MydiaWeb.DeviceChannel, "device:reconnect", %{})

      # Send deprecated handshake_init message
      ref = push(socket, "handshake_init", %{"message" => Base.encode64("some-data")})

      # Should receive error directing to use key_exchange
      assert_reply ref, :error, %{reason: "use_key_exchange"}
    end
  end

  describe "device updates" do
    test "updates last_seen_at after successful key exchange", %{
      device: device,
      device_token: device_token,
      device_keypair: {device_public_key, _device_private_key}
    } do
      old_last_seen = device.last_seen_at

      # Join the channel
      {:ok, _reply, socket} =
        socket(MydiaWeb.UserSocket, "user_id", %{})
        |> subscribe_and_join(MydiaWeb.DeviceChannel, "device:reconnect", %{})

      # Complete key exchange
      ref =
        push(socket, "key_exchange", %{
          "client_public_key" => Base.encode64(device_public_key),
          "device_token" => device_token
        })

      # Note: Increased timeout due to Argon2 token verification (~80ms)
      assert_reply ref, :ok, %{device_id: device_id}, 500

      # Reload device and check last_seen_at was updated
      updated_device = RemoteAccess.get_device!(device_id)
      refute updated_device.last_seen_at == old_last_seen
      assert DateTime.compare(updated_device.last_seen_at, DateTime.utc_now()) in [:lt, :eq]
    end
  end

  describe "join device:pair" do
    test "successfully joins the pairing channel" do
      assert {:ok, _reply, socket} =
               socket(MydiaWeb.UserSocket, "user_id", %{})
               |> subscribe_and_join(MydiaWeb.DeviceChannel, "device:pair", %{})

      # Verify server keypair is assigned (new X25519 protocol)
      assert socket.assigns.server_public_key
      assert socket.assigns.server_private_key
      assert byte_size(socket.assigns.server_public_key) == 32
    end
  end

  describe "pairing_handshake (X25519)" do
    test "successfully completes X25519 handshake" do
      # Join the pairing channel
      {:ok, _reply, socket} =
        socket(MydiaWeb.UserSocket, "user_id", %{})
        |> subscribe_and_join(MydiaWeb.DeviceChannel, "device:pair", %{})

      # Generate client ephemeral keypair
      {client_public_key, _client_private_key} = Mydia.Crypto.generate_keypair()

      # Send pairing_handshake message with client's public key
      ref =
        push(socket, "pairing_handshake", %{"message" => Base.encode64(client_public_key)})

      # Should receive successful reply with server's public key
      assert_reply ref, :ok, %{message: server_public_key_b64}

      # Verify we got a valid response
      assert is_binary(server_public_key_b64)
      assert {:ok, server_public_key} = Base.decode64(server_public_key_b64)
      assert byte_size(server_public_key) == 32
    end

    test "rejects invalid public key" do
      # Join the pairing channel
      {:ok, _reply, socket} =
        socket(MydiaWeb.UserSocket, "user_id", %{})
        |> subscribe_and_join(MydiaWeb.DeviceChannel, "device:pair", %{})

      # Send invalid key (wrong size)
      ref = push(socket, "pairing_handshake", %{"message" => Base.encode64("short")})

      # Should receive error
      assert_reply ref, :error, %{reason: "invalid_message"}
    end

    test "rejects invalid base64 message" do
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

      # Complete X25519 handshake first
      {client_public_key, _client_private_key} = Mydia.Crypto.generate_keypair()

      ref =
        push(socket, "pairing_handshake", %{"message" => Base.encode64(client_public_key)})

      assert_reply ref, :ok, %{message: _server_public_key_b64}

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

      {client_public_key, _client_private_key} = Mydia.Crypto.generate_keypair()

      ref =
        push(socket, "pairing_handshake", %{"message" => Base.encode64(client_public_key)})

      assert_reply ref, :ok, %{message: _server_public_key_b64}

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

      {client_public_key, _client_private_key} = Mydia.Crypto.generate_keypair()

      ref =
        push(socket, "pairing_handshake", %{"message" => Base.encode64(client_public_key)})

      assert_reply ref, :ok, %{message: _server_public_key_b64}

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
