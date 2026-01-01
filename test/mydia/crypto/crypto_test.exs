defmodule Mydia.CryptoTest do
  use ExUnit.Case, async: true

  alias Mydia.Crypto

  describe "generate_keypair/0" do
    test "generates a valid keypair with 32-byte keys" do
      {public_key, private_key} = Crypto.generate_keypair()

      assert byte_size(public_key) == 32
      assert byte_size(private_key) == 32
    end

    test "generates unique keypairs each time" do
      {pub1, priv1} = Crypto.generate_keypair()
      {pub2, priv2} = Crypto.generate_keypair()

      refute pub1 == pub2
      refute priv1 == priv2
    end

    test "public and private keys are different" do
      {public_key, private_key} = Crypto.generate_keypair()

      refute public_key == private_key
    end
  end

  describe "derive_session_key/2" do
    test "derives a 32-byte session key" do
      {_alice_pub, alice_priv} = Crypto.generate_keypair()
      {bob_pub, _bob_priv} = Crypto.generate_keypair()

      session_key = Crypto.derive_session_key(alice_priv, bob_pub)

      assert byte_size(session_key) == 32
    end

    test "both parties derive the same session key" do
      {alice_pub, alice_priv} = Crypto.generate_keypair()
      {bob_pub, bob_priv} = Crypto.generate_keypair()

      alice_session = Crypto.derive_session_key(alice_priv, bob_pub)
      bob_session = Crypto.derive_session_key(bob_priv, alice_pub)

      assert alice_session == bob_session
    end

    test "different keypairs produce different session keys" do
      {_alice_pub, alice_priv} = Crypto.generate_keypair()
      {bob_pub, _bob_priv} = Crypto.generate_keypair()
      {charlie_pub, _charlie_priv} = Crypto.generate_keypair()

      session1 = Crypto.derive_session_key(alice_priv, bob_pub)
      session2 = Crypto.derive_session_key(alice_priv, charlie_pub)

      refute session1 == session2
    end

    test "uses custom salt and info when provided" do
      {alice_pub, alice_priv} = Crypto.generate_keypair()
      {bob_pub, bob_priv} = Crypto.generate_keypair()

      default_key = Crypto.derive_session_key(alice_priv, bob_pub)

      custom_key =
        Crypto.derive_session_key(alice_priv, bob_pub, salt: "my-salt", info: "my-info")

      refute default_key == custom_key

      # Verify both parties still get the same key with custom options
      alice_custom =
        Crypto.derive_session_key(alice_priv, bob_pub, salt: "my-salt", info: "my-info")

      bob_custom =
        Crypto.derive_session_key(bob_priv, alice_pub, salt: "my-salt", info: "my-info")

      assert alice_custom == bob_custom
    end
  end

  describe "encrypt/2 and decrypt/4 round-trip" do
    test "encrypts and decrypts a simple message" do
      {alice_pub, alice_priv} = Crypto.generate_keypair()
      {bob_pub, bob_priv} = Crypto.generate_keypair()

      alice_key = Crypto.derive_session_key(alice_priv, bob_pub)
      bob_key = Crypto.derive_session_key(bob_priv, alice_pub)

      plaintext = "Hello, World!"
      encrypted = Crypto.encrypt(plaintext, alice_key)

      assert {:ok, ^plaintext} =
               Crypto.decrypt(encrypted.ciphertext, encrypted.nonce, encrypted.mac, bob_key)
    end

    test "encrypts and decrypts empty message" do
      {_pub, priv} = Crypto.generate_keypair()
      {peer_pub, _peer_priv} = Crypto.generate_keypair()

      key = Crypto.derive_session_key(priv, peer_pub)

      plaintext = ""
      encrypted = Crypto.encrypt(plaintext, key)

      assert {:ok, ^plaintext} =
               Crypto.decrypt(encrypted.ciphertext, encrypted.nonce, encrypted.mac, key)
    end

    test "encrypts and decrypts binary data" do
      {_pub, priv} = Crypto.generate_keypair()
      {peer_pub, _peer_priv} = Crypto.generate_keypair()

      key = Crypto.derive_session_key(priv, peer_pub)

      plaintext = :crypto.strong_rand_bytes(1024)
      encrypted = Crypto.encrypt(plaintext, key)

      assert {:ok, ^plaintext} =
               Crypto.decrypt(encrypted.ciphertext, encrypted.nonce, encrypted.mac, key)
    end

    test "encrypts and decrypts large data" do
      {_pub, priv} = Crypto.generate_keypair()
      {peer_pub, _peer_priv} = Crypto.generate_keypair()

      key = Crypto.derive_session_key(priv, peer_pub)

      # 1 MB of data
      plaintext = :crypto.strong_rand_bytes(1024 * 1024)
      encrypted = Crypto.encrypt(plaintext, key)

      assert {:ok, ^plaintext} =
               Crypto.decrypt(encrypted.ciphertext, encrypted.nonce, encrypted.mac, key)
    end
  end

  describe "encrypt/2" do
    test "returns encrypted data with correct structure" do
      {_pub, priv} = Crypto.generate_keypair()
      {peer_pub, _peer_priv} = Crypto.generate_keypair()

      key = Crypto.derive_session_key(priv, peer_pub)

      encrypted = Crypto.encrypt("test", key)

      assert is_map(encrypted)
      assert Map.has_key?(encrypted, :ciphertext)
      assert Map.has_key?(encrypted, :nonce)
      assert Map.has_key?(encrypted, :mac)
    end

    test "generates 12-byte nonce" do
      {_pub, priv} = Crypto.generate_keypair()
      {peer_pub, _peer_priv} = Crypto.generate_keypair()

      key = Crypto.derive_session_key(priv, peer_pub)

      encrypted = Crypto.encrypt("test", key)

      assert byte_size(encrypted.nonce) == 12
    end

    test "generates 16-byte MAC" do
      {_pub, priv} = Crypto.generate_keypair()
      {peer_pub, _peer_priv} = Crypto.generate_keypair()

      key = Crypto.derive_session_key(priv, peer_pub)

      encrypted = Crypto.encrypt("test", key)

      assert byte_size(encrypted.mac) == 16
    end

    test "generates unique nonce for each encryption" do
      {_pub, priv} = Crypto.generate_keypair()
      {peer_pub, _peer_priv} = Crypto.generate_keypair()

      key = Crypto.derive_session_key(priv, peer_pub)

      encrypted1 = Crypto.encrypt("test", key)
      encrypted2 = Crypto.encrypt("test", key)
      encrypted3 = Crypto.encrypt("test", key)

      refute encrypted1.nonce == encrypted2.nonce
      refute encrypted2.nonce == encrypted3.nonce
      refute encrypted1.nonce == encrypted3.nonce
    end

    test "ciphertext differs even for same plaintext due to random nonce" do
      {_pub, priv} = Crypto.generate_keypair()
      {peer_pub, _peer_priv} = Crypto.generate_keypair()

      key = Crypto.derive_session_key(priv, peer_pub)

      encrypted1 = Crypto.encrypt("same message", key)
      encrypted2 = Crypto.encrypt("same message", key)

      refute encrypted1.ciphertext == encrypted2.ciphertext
    end
  end

  describe "decrypt/4 MAC verification" do
    test "fails when ciphertext is tampered" do
      {_pub, priv} = Crypto.generate_keypair()
      {peer_pub, _peer_priv} = Crypto.generate_keypair()

      key = Crypto.derive_session_key(priv, peer_pub)

      encrypted = Crypto.encrypt("secret message", key)

      # Tamper with ciphertext by flipping a bit
      <<first_byte, rest::binary>> = encrypted.ciphertext
      tampered_ciphertext = <<Bitwise.bxor(first_byte, 1), rest::binary>>

      assert {:error, :decryption_failed} =
               Crypto.decrypt(tampered_ciphertext, encrypted.nonce, encrypted.mac, key)
    end

    test "fails when MAC is tampered" do
      {_pub, priv} = Crypto.generate_keypair()
      {peer_pub, _peer_priv} = Crypto.generate_keypair()

      key = Crypto.derive_session_key(priv, peer_pub)

      encrypted = Crypto.encrypt("secret message", key)

      # Tamper with MAC by flipping a bit
      <<first_byte, rest::binary>> = encrypted.mac
      tampered_mac = <<Bitwise.bxor(first_byte, 1), rest::binary>>

      assert {:error, :decryption_failed} =
               Crypto.decrypt(encrypted.ciphertext, encrypted.nonce, tampered_mac, key)
    end

    test "fails when nonce is tampered" do
      {_pub, priv} = Crypto.generate_keypair()
      {peer_pub, _peer_priv} = Crypto.generate_keypair()

      key = Crypto.derive_session_key(priv, peer_pub)

      encrypted = Crypto.encrypt("secret message", key)

      # Tamper with nonce by flipping a bit
      <<first_byte, rest::binary>> = encrypted.nonce
      tampered_nonce = <<Bitwise.bxor(first_byte, 1), rest::binary>>

      assert {:error, :decryption_failed} =
               Crypto.decrypt(encrypted.ciphertext, tampered_nonce, encrypted.mac, key)
    end

    test "fails with completely wrong MAC" do
      {_pub, priv} = Crypto.generate_keypair()
      {peer_pub, _peer_priv} = Crypto.generate_keypair()

      key = Crypto.derive_session_key(priv, peer_pub)

      encrypted = Crypto.encrypt("secret message", key)

      # Use a completely random MAC
      random_mac = :crypto.strong_rand_bytes(16)

      assert {:error, :decryption_failed} =
               Crypto.decrypt(encrypted.ciphertext, encrypted.nonce, random_mac, key)
    end
  end

  describe "decrypt/4 with wrong key" do
    test "fails when decrypting with a different key" do
      {_pub, priv} = Crypto.generate_keypair()
      {peer_pub, _peer_priv} = Crypto.generate_keypair()

      correct_key = Crypto.derive_session_key(priv, peer_pub)

      # Generate a completely different keypair for wrong key
      {_wrong_pub, wrong_priv} = Crypto.generate_keypair()
      {other_pub, _other_priv} = Crypto.generate_keypair()
      wrong_key = Crypto.derive_session_key(wrong_priv, other_pub)

      encrypted = Crypto.encrypt("secret message", correct_key)

      assert {:error, :decryption_failed} =
               Crypto.decrypt(encrypted.ciphertext, encrypted.nonce, encrypted.mac, wrong_key)
    end

    test "fails when decrypting with random bytes as key" do
      {_pub, priv} = Crypto.generate_keypair()
      {peer_pub, _peer_priv} = Crypto.generate_keypair()

      key = Crypto.derive_session_key(priv, peer_pub)

      encrypted = Crypto.encrypt("secret message", key)

      random_key = :crypto.strong_rand_bytes(32)

      assert {:error, :decryption_failed} =
               Crypto.decrypt(encrypted.ciphertext, encrypted.nonce, encrypted.mac, random_key)
    end
  end

  describe "decrypt/4 with invalid parameters" do
    test "fails with wrong nonce size" do
      {_pub, priv} = Crypto.generate_keypair()
      {peer_pub, _peer_priv} = Crypto.generate_keypair()

      key = Crypto.derive_session_key(priv, peer_pub)

      encrypted = Crypto.encrypt("secret message", key)

      # Use a nonce with wrong size (8 bytes instead of 12)
      wrong_size_nonce = :crypto.strong_rand_bytes(8)

      assert {:error, :decryption_failed} =
               Crypto.decrypt(encrypted.ciphertext, wrong_size_nonce, encrypted.mac, key)
    end

    test "fails with wrong MAC size" do
      {_pub, priv} = Crypto.generate_keypair()
      {peer_pub, _peer_priv} = Crypto.generate_keypair()

      key = Crypto.derive_session_key(priv, peer_pub)

      encrypted = Crypto.encrypt("secret message", key)

      # Use a MAC with wrong size (8 bytes instead of 16)
      wrong_size_mac = :crypto.strong_rand_bytes(8)

      assert {:error, :decryption_failed} =
               Crypto.decrypt(encrypted.ciphertext, encrypted.nonce, wrong_size_mac, key)
    end

    test "fails with wrong key size" do
      {_pub, priv} = Crypto.generate_keypair()
      {peer_pub, _peer_priv} = Crypto.generate_keypair()

      key = Crypto.derive_session_key(priv, peer_pub)

      encrypted = Crypto.encrypt("secret message", key)

      # Use a key with wrong size (16 bytes instead of 32)
      wrong_size_key = :crypto.strong_rand_bytes(16)

      assert {:error, :decryption_failed} =
               Crypto.decrypt(
                 encrypted.ciphertext,
                 encrypted.nonce,
                 encrypted.mac,
                 wrong_size_key
               )
    end
  end

  describe "end-to-end encryption scenario" do
    test "simulates secure communication between two parties" do
      # Alice and Bob generate their keypairs
      {alice_pub, alice_priv} = Crypto.generate_keypair()
      {bob_pub, bob_priv} = Crypto.generate_keypair()

      # Both derive the same session key
      alice_session = Crypto.derive_session_key(alice_priv, bob_pub)
      bob_session = Crypto.derive_session_key(bob_priv, alice_pub)

      assert alice_session == bob_session

      # Alice sends a message to Bob
      alice_message = "Hello Bob, this is a secret message!"
      encrypted = Crypto.encrypt(alice_message, alice_session)

      # Bob decrypts the message
      assert {:ok, ^alice_message} =
               Crypto.decrypt(encrypted.ciphertext, encrypted.nonce, encrypted.mac, bob_session)

      # Bob replies to Alice
      bob_message = "Hi Alice, I received your message!"
      reply_encrypted = Crypto.encrypt(bob_message, bob_session)

      # Alice decrypts Bob's reply
      assert {:ok, ^bob_message} =
               Crypto.decrypt(
                 reply_encrypted.ciphertext,
                 reply_encrypted.nonce,
                 reply_encrypted.mac,
                 alice_session
               )
    end

    test "third party cannot decrypt the communication" do
      # Alice and Bob's keypairs
      {alice_pub, alice_priv} = Crypto.generate_keypair()
      {bob_pub, _bob_priv} = Crypto.generate_keypair()

      # Eve (attacker) has her own keypair
      {_eve_pub, eve_priv} = Crypto.generate_keypair()

      # Alice and Bob establish session
      alice_session = Crypto.derive_session_key(alice_priv, bob_pub)

      # Eve tries to compute a session key with what she has
      # (she doesn't have Alice's or Bob's private keys)
      eve_session_attempt1 = Crypto.derive_session_key(eve_priv, alice_pub)
      eve_session_attempt2 = Crypto.derive_session_key(eve_priv, bob_pub)

      # Alice sends an encrypted message
      encrypted = Crypto.encrypt("Top secret data", alice_session)

      # Eve cannot decrypt with her computed keys
      assert {:error, :decryption_failed} =
               Crypto.decrypt(
                 encrypted.ciphertext,
                 encrypted.nonce,
                 encrypted.mac,
                 eve_session_attempt1
               )

      assert {:error, :decryption_failed} =
               Crypto.decrypt(
                 encrypted.ciphertext,
                 encrypted.nonce,
                 encrypted.mac,
                 eve_session_attempt2
               )
    end
  end
end
