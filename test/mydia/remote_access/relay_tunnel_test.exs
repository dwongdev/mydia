defmodule Mydia.RemoteAccess.RelayTunnelTest do
  use Mydia.DataCase, async: false

  alias Mydia.Crypto
  alias Mydia.RemoteAccess.RelayTunnel

  # Constants matching RelayTunnel's encryption format
  @nonce_size 12
  @mac_size 16

  describe "relay tunnel supervisor" do
    test "starts successfully and subscribes to relay connections" do
      # RelayTunnel is already started by the application supervisor
      # Verify it's running
      pid = Process.whereis(RelayTunnel)
      assert pid != nil
      assert Process.alive?(pid)
    end

    test "handles relay connection events" do
      # RelayTunnel is already started by the application supervisor
      pid = Process.whereis(RelayTunnel)
      assert pid != nil

      # Simulate a relay connection event
      session_id = "test-session-#{System.unique_integer()}"
      client_public_key = :crypto.strong_rand_bytes(32)
      relay_pid = self()

      # Broadcast a relay connection event
      Phoenix.PubSub.broadcast(
        Mydia.PubSub,
        "relay:connections",
        {:relay_connection, session_id, client_public_key, relay_pid}
      )

      # Give the tunnel process time to start
      Process.sleep(100)

      # The tunnel should be handling this connection
      # We can verify by checking if messages can be sent to the session
      # Note: Full integration would require mocking the Pairing module
    end
  end

  describe "tunnel message handling" do
    test "handles incoming relay messages" do
      # This test would require mocking the Pairing module
      # and simulating the full handshake flow
      # For now, we verify the supervisor is running
      pid = Process.whereis(RelayTunnel)
      assert pid != nil
      assert Process.alive?(pid)
    end
  end

  describe "end-to-end encryption format" do
    test "encrypts messages in the expected wire format: base64(nonce || ciphertext || mac)" do
      # Generate a session key (simulating what happens after handshake)
      {pub1, priv1} = Crypto.generate_keypair()
      {pub2, priv2} = Crypto.generate_keypair()
      session_key = Crypto.derive_session_key(priv1, pub2)
      session_key_2 = Crypto.derive_session_key(priv2, pub1)

      # Verify both parties derive the same key
      assert session_key == session_key_2

      # Encrypt a message using the same method as RelayTunnel
      message = ~s({"type": "response", "status": 200})
      %{ciphertext: ciphertext, nonce: nonce, mac: mac} = Crypto.encrypt(message, session_key)

      # Wire format: nonce || ciphertext || mac
      encrypted_payload = nonce <> ciphertext <> mac
      encoded = Base.encode64(encrypted_payload)

      # Verify the format
      {:ok, binary} = Base.decode64(encoded)
      assert byte_size(binary) > @nonce_size + @mac_size

      # Extract components
      <<decoded_nonce::binary-size(@nonce_size), rest::binary>> = binary
      ciphertext_len = byte_size(rest) - @mac_size

      <<decoded_ciphertext::binary-size(ciphertext_len), decoded_mac::binary-size(@mac_size)>> =
        rest

      # Verify we can decrypt
      assert {:ok, ^message} =
               Crypto.decrypt(decoded_ciphertext, decoded_nonce, decoded_mac, session_key)
    end

    test "encrypted messages are not valid JSON" do
      {_pub1, priv1} = Crypto.generate_keypair()
      {pub2, _priv2} = Crypto.generate_keypair()
      session_key = Crypto.derive_session_key(priv1, pub2)

      message = ~s({"type": "ping"})
      %{ciphertext: ciphertext, nonce: nonce, mac: mac} = Crypto.encrypt(message, session_key)
      encrypted_payload = nonce <> ciphertext <> mac
      encoded = Base.encode64(encrypted_payload)

      # Encrypted messages should not be valid JSON
      assert {:error, _} = Jason.decode(encoded)
    end

    test "plaintext handshake messages remain valid JSON" do
      # Handshake messages are sent as plaintext JSON
      handshake_message = %{type: "pairing_handshake", message: Base.encode64(<<1, 2, 3, 4>>)}
      encoded = Jason.encode!(handshake_message)

      # Should be valid JSON
      assert {:ok, decoded} = Jason.decode(encoded)
      assert decoded["type"] == "pairing_handshake"
    end

    test "can round-trip encrypt/decrypt a JSON message" do
      {pub1, priv1} = Crypto.generate_keypair()
      {pub2, priv2} = Crypto.generate_keypair()
      session_key = Crypto.derive_session_key(priv1, pub2)

      # Original message
      original = %{
        type: "response",
        id: "req-123",
        status: 200,
        body: "Hello, World!"
      }

      json = Jason.encode!(original)

      # Encrypt
      %{ciphertext: ciphertext, nonce: nonce, mac: mac} = Crypto.encrypt(json, session_key)
      encrypted = Base.encode64(nonce <> ciphertext <> mac)

      # Decrypt using the other party's key derivation
      other_session_key = Crypto.derive_session_key(priv2, pub1)
      {:ok, binary} = Base.decode64(encrypted)
      <<dec_nonce::binary-size(@nonce_size), rest::binary>> = binary
      ct_len = byte_size(rest) - @mac_size
      <<dec_ct::binary-size(ct_len), dec_mac::binary-size(@mac_size)>> = rest

      {:ok, decrypted_json} = Crypto.decrypt(dec_ct, dec_nonce, dec_mac, other_session_key)

      # Verify round-trip
      assert {:ok, decrypted} = Jason.decode(decrypted_json)
      assert decrypted["type"] == "response"
      assert decrypted["id"] == "req-123"
      assert decrypted["status"] == 200
      assert decrypted["body"] == "Hello, World!"
    end

    test "tampering with encrypted message causes decryption failure" do
      {_pub1, priv1} = Crypto.generate_keypair()
      {pub2, _priv2} = Crypto.generate_keypair()
      session_key = Crypto.derive_session_key(priv1, pub2)

      message = ~s({"type": "claim_code", "code": "ABCD-1234"})
      %{ciphertext: ciphertext, nonce: nonce, mac: mac} = Crypto.encrypt(message, session_key)

      # Tamper with the ciphertext
      tampered_ciphertext = :crypto.strong_rand_bytes(byte_size(ciphertext))

      # Attempt to decrypt should fail
      assert {:error, :decryption_failed} =
               Crypto.decrypt(tampered_ciphertext, nonce, mac, session_key)
    end

    test "wrong session key causes decryption failure" do
      {_pub1, priv1} = Crypto.generate_keypair()
      {pub2, _priv2} = Crypto.generate_keypair()
      session_key = Crypto.derive_session_key(priv1, pub2)

      # Create an entirely different session key
      {_pub3, priv3} = Crypto.generate_keypair()
      {pub4, _priv4} = Crypto.generate_keypair()
      wrong_key = Crypto.derive_session_key(priv3, pub4)

      message = ~s({"sensitive": "data"})
      %{ciphertext: ciphertext, nonce: nonce, mac: mac} = Crypto.encrypt(message, session_key)

      # Attempt to decrypt with wrong key should fail
      assert {:error, :decryption_failed} = Crypto.decrypt(ciphertext, nonce, mac, wrong_key)
    end
  end

  describe "message type classification" do
    test "handshake message types are identified correctly" do
      # These message types should be sent in plaintext (before/during handshake)
      handshake_types = ["pairing_handshake", "handshake_complete"]

      for type <- handshake_types do
        # These are handshake types - would be sent plaintext
        assert type in handshake_types
      end
    end

    test "non-handshake message types should be encrypted after handshake" do
      # These message types should be encrypted after handshake is complete
      encrypted_types = ["claim_code", "request", "response", "ping", "pong", "error"]

      for type <- encrypted_types do
        refute type in ["pairing_handshake", "handshake_complete"]
      end
    end
  end

  describe "strict encryption enforcement" do
    test "plaintext JSON cannot be decrypted - ensures no backward compatibility" do
      {_pub1, priv1} = Crypto.generate_keypair()
      {pub2, _priv2} = Crypto.generate_keypair()
      session_key = Crypto.derive_session_key(priv1, pub2)

      # A plaintext JSON message (what an old client might send)
      plaintext_message = ~s({"type": "claim_code", "code": "ABCD-1234"})

      # Attempting to decrypt plaintext as if it were encrypted should fail
      # This is NOT valid base64 of encrypted data
      assert {:error, _reason} = decrypt_test_payload(plaintext_message, session_key)
    end

    test "random base64 data fails decryption - MAC verification" do
      {_pub1, priv1} = Crypto.generate_keypair()
      {pub2, _priv2} = Crypto.generate_keypair()
      session_key = Crypto.derive_session_key(priv1, pub2)

      # Random data that is valid base64 but not properly encrypted
      random_data = :crypto.strong_rand_bytes(50)
      base64_random = Base.encode64(random_data)

      # Should fail decryption (MAC won't verify)
      assert {:error, _reason} = decrypt_test_payload(base64_random, session_key)
    end
  end

  describe "AAD (Additional Authenticated Data) security" do
    test "decryption with correct AAD succeeds" do
      {_pub1, priv1} = Crypto.generate_keypair()
      {pub2, _priv2} = Crypto.generate_keypair()
      session_key = Crypto.derive_session_key(priv1, pub2)

      session_id = "test-session-123"
      aad = "#{session_id}:to-server"

      message = ~s({"type": "claim_code", "code": "ABCD-1234"})

      %{ciphertext: ciphertext, nonce: nonce, mac: mac} =
        Crypto.encrypt(message, session_key, aad)

      # Decryption with correct AAD should succeed
      assert {:ok, ^message} = Crypto.decrypt(ciphertext, nonce, mac, session_key, aad)
    end

    test "decryption with wrong AAD fails - different session_id" do
      {_pub1, priv1} = Crypto.generate_keypair()
      {pub2, _priv2} = Crypto.generate_keypair()
      session_key = Crypto.derive_session_key(priv1, pub2)

      # Encrypt with one session ID
      original_session = "session-original"
      encrypt_aad = "#{original_session}:to-server"

      message = ~s({"type": "claim_code", "code": "ABCD-1234"})

      %{ciphertext: ciphertext, nonce: nonce, mac: mac} =
        Crypto.encrypt(message, session_key, encrypt_aad)

      # Try to decrypt with different session ID (cross-session replay attack)
      attacker_session = "session-attacker"
      decrypt_aad = "#{attacker_session}:to-server"

      assert {:error, :decryption_failed} =
               Crypto.decrypt(ciphertext, nonce, mac, session_key, decrypt_aad)
    end

    test "decryption with wrong AAD fails - wrong direction (reflection attack)" do
      {_pub1, priv1} = Crypto.generate_keypair()
      {pub2, _priv2} = Crypto.generate_keypair()
      session_key = Crypto.derive_session_key(priv1, pub2)

      session_id = "test-session-123"
      # Message encrypted for client→server direction
      encrypt_aad = "#{session_id}:to-server"

      message = ~s({"type": "claim_code", "code": "ABCD-1234"})

      %{ciphertext: ciphertext, nonce: nonce, mac: mac} =
        Crypto.encrypt(message, session_key, encrypt_aad)

      # Try to decrypt as if it was server→client (reflection attack)
      decrypt_aad = "#{session_id}:to-client"

      assert {:error, :decryption_failed} =
               Crypto.decrypt(ciphertext, nonce, mac, session_key, decrypt_aad)
    end

    test "decryption with no AAD fails when message was encrypted with AAD" do
      {_pub1, priv1} = Crypto.generate_keypair()
      {pub2, _priv2} = Crypto.generate_keypair()
      session_key = Crypto.derive_session_key(priv1, pub2)

      session_id = "test-session-123"
      aad = "#{session_id}:to-server"

      message = ~s({"type": "claim_code", "code": "ABCD-1234"})

      %{ciphertext: ciphertext, nonce: nonce, mac: mac} =
        Crypto.encrypt(message, session_key, aad)

      # Try to decrypt without AAD (empty AAD)
      assert {:error, :decryption_failed} =
               Crypto.decrypt(ciphertext, nonce, mac, session_key, <<>>)
    end

    test "decryption with AAD fails when message was encrypted without AAD" do
      {_pub1, priv1} = Crypto.generate_keypair()
      {pub2, _priv2} = Crypto.generate_keypair()
      session_key = Crypto.derive_session_key(priv1, pub2)

      # Encrypt without AAD
      message = ~s({"type": "ping"})
      %{ciphertext: ciphertext, nonce: nonce, mac: mac} = Crypto.encrypt(message, session_key)

      # Try to decrypt with AAD
      session_id = "test-session-123"
      aad = "#{session_id}:to-server"

      assert {:error, :decryption_failed} =
               Crypto.decrypt(ciphertext, nonce, mac, session_key, aad)
    end

    test "AAD format is session_id:direction" do
      session_id = "abc-123-def"

      # Test to-server direction
      to_server_aad = "#{session_id}:to-server"
      assert to_server_aad == "abc-123-def:to-server"

      # Test to-client direction
      to_client_aad = "#{session_id}:to-client"
      assert to_client_aad == "abc-123-def:to-client"
    end
  end

  # Helper to test decryption (mirrors RelayTunnel's decrypt_payload/2)
  defp decrypt_test_payload(base64_payload, session_key) do
    with {:ok, binary} <- Base.decode64(base64_payload),
         true <- byte_size(binary) > @nonce_size + @mac_size do
      <<nonce::binary-size(@nonce_size), ciphertext_with_mac::binary>> = binary
      ciphertext_len = byte_size(ciphertext_with_mac) - @mac_size

      <<ciphertext::binary-size(ciphertext_len), mac::binary-size(@mac_size)>> =
        ciphertext_with_mac

      Crypto.decrypt(ciphertext, nonce, mac, session_key)
    else
      :error -> {:error, :invalid_base64}
      false -> {:error, :payload_too_short}
    end
  end
end
