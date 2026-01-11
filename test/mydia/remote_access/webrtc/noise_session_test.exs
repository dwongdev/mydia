defmodule Mydia.RemoteAccess.WebRTC.NoiseSessionTest do
  use ExUnit.Case, async: true

  alias Mydia.RemoteAccess.WebRTC.NoiseSession

  @protocol_name "Noise_IK_25519_ChaChaPoly_SHA256"

  # Generate X25519 keypair for testing
  defp generate_keypair do
    :crypto.generate_key(:ecdh, :x25519)
  end

  describe "new_responder/3" do
    test "creates a new noise session with valid keypair" do
      keypair = generate_keypair()
      session_id = Ecto.UUID.generate()
      instance_id = Ecto.UUID.generate()

      assert {:ok, session} = NoiseSession.new_responder(keypair, session_id, instance_id)
      assert session.session_id == session_id
      assert session.instance_id == instance_id
      assert session.state == :handshake
      assert session.tx_counter == 0
      assert session.rx_counter == 0
    end

    test "fails with invalid keypair" do
      # Wrong key size - guard clause will not match
      assert_raise FunctionClauseError, fn ->
        NoiseSession.new_responder({<<1, 2, 3>>, <<4, 5, 6>>}, "session", "instance")
      end
    end
  end

  describe "handshake_complete?/1" do
    test "returns false for new session" do
      keypair = generate_keypair()
      {:ok, session} = NoiseSession.new_responder(keypair, "session", "instance")

      refute NoiseSession.handshake_complete?(session)
    end
  end

  describe "full handshake and transport" do
    test "completes handshake and encrypts/decrypts data" do
      # Server keypair
      server_keypair = generate_keypair()
      {server_public, _server_private} = server_keypair
      session_id = Ecto.UUID.generate()
      instance_id = Ecto.UUID.generate()

      # Create responder (server)
      {:ok, server_session} = NoiseSession.new_responder(server_keypair, session_id, instance_id)

      # Create initiator (client) using Decibel directly
      prologue = session_id <> instance_id <> <<1>>
      client_keypair = generate_keypair()
      {client_public, client_private} = client_keypair

      client_ref =
        Decibel.new(
          @protocol_name,
          :ini,
          %{s: {client_public, client_private}, rs: server_public, prologue: prologue}
        )

      # Client sends handshake message 1
      msg1 = Decibel.handshake_encrypt(client_ref, <<>>)

      # Server processes message 1 and sends message 2
      {:ok, server_session, msg2} =
        NoiseSession.process_handshake(server_session, IO.iodata_to_binary(msg1))

      assert msg2 != nil

      # Client processes message 2
      _payload = Decibel.handshake_decrypt(client_ref, msg2)
      assert Decibel.is_handshake_complete?(client_ref)
      assert NoiseSession.handshake_complete?(server_session)

      # Test transport mode - server encrypts, client decrypts
      plaintext = "Hello, client!"
      {:ok, server_session, ciphertext} = NoiseSession.encrypt(server_session, :api, plaintext)

      # Parse the framed message and decrypt with client
      <<1, 1, 0, counter::big-64, encrypted::binary>> = ciphertext
      ad = <<1, 1, 0, counter::big-64>>
      Decibel.set_nonce(client_ref, :in, counter)
      decrypted = Decibel.decrypt(client_ref, encrypted, ad)
      assert IO.iodata_to_binary(decrypted) == plaintext

      # Test client -> server
      client_plaintext = "Hello, server!"
      client_ad = <<1, 1, 0, 0::big-64>>
      client_encrypted = Decibel.encrypt(client_ref, client_plaintext, client_ad)
      client_framed = client_ad <> IO.iodata_to_binary(client_encrypted)

      {:ok, _server_session, channel, server_decrypted} =
        NoiseSession.decrypt(server_session, client_framed)

      assert channel == :api
      assert server_decrypted == client_plaintext

      # Cleanup
      Decibel.close(client_ref)
    end

    test "rejects replay attacks via counter check" do
      # Setup handshake
      server_keypair = generate_keypair()
      {server_public, _} = server_keypair
      session_id = Ecto.UUID.generate()
      instance_id = Ecto.UUID.generate()

      {:ok, server_session} = NoiseSession.new_responder(server_keypair, session_id, instance_id)

      prologue = session_id <> instance_id <> <<1>>
      client_keypair = generate_keypair()
      {client_public, client_private} = client_keypair

      client_ref =
        Decibel.new(
          @protocol_name,
          :ini,
          %{s: {client_public, client_private}, rs: server_public, prologue: prologue}
        )

      msg1 = Decibel.handshake_encrypt(client_ref, <<>>)

      {:ok, server_session, msg2} =
        NoiseSession.process_handshake(server_session, IO.iodata_to_binary(msg1))

      Decibel.handshake_decrypt(client_ref, msg2)

      # Client sends first message (counter 0)
      ad1 = <<1, 1, 0, 0::big-64>>
      encrypted1 = Decibel.encrypt(client_ref, "message 1", ad1)
      framed1 = ad1 <> IO.iodata_to_binary(encrypted1)

      {:ok, server_session, :api, _} = NoiseSession.decrypt(server_session, framed1)

      # After decryption, server's rx_counter is 0
      # Replay with same counter will fail due to counter check (counter <= last_seen)
      # However, the decibel nonce will also be out of sync, causing decryption failure
      # Either error is acceptable for replay protection
      result = NoiseSession.decrypt(server_session, framed1)
      assert {:error, reason} = result
      assert reason in [:replay_detected, :decryption_failed]

      Decibel.close(client_ref)
    end
  end

  describe "metrics/1" do
    test "returns session metrics" do
      keypair = generate_keypair()
      {:ok, session} = NoiseSession.new_responder(keypair, "session-123", "instance-456")

      metrics = NoiseSession.metrics(session)

      assert metrics.session_id == "session-123"
      assert metrics.state == :handshake
      assert metrics.tx_counter == 0
      assert metrics.rx_counter == 0
      assert metrics.handshake_complete == false
    end
  end

  describe "needs_rekey_tx?/1 and needs_rekey_rx?/1" do
    test "returns false for new session" do
      keypair = generate_keypair()
      {:ok, session} = NoiseSession.new_responder(keypair, "session", "instance")

      refute NoiseSession.needs_rekey_tx?(session)
      refute NoiseSession.needs_rekey_rx?(session)
    end
  end

  describe "is_transport_message?/1" do
    test "identifies transport messages by header" do
      # Valid transport message header
      assert NoiseSession.is_transport_message?(<<1, 1, 0, 0::big-64, "payload">>)
      assert NoiseSession.is_transport_message?(<<1, 2, 0, 0::big-64, "payload">>)

      # Invalid - wrong version
      refute NoiseSession.is_transport_message?(<<2, 1, 0, 0::big-64, "payload">>)

      # Invalid - wrong channel
      refute NoiseSession.is_transport_message?(<<1, 3, 0, 0::big-64, "payload">>)

      # Invalid - wrong flags
      refute NoiseSession.is_transport_message?(<<1, 1, 1, 0::big-64, "payload">>)

      # Handshake message (starts with ephemeral public key)
      refute NoiseSession.is_transport_message?(:crypto.strong_rand_bytes(96))
    end
  end
end
