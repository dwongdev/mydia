defmodule Mydia.Crypto.CrossPlatformTest do
  @moduledoc """
  Cross-platform compatibility tests for E2EE crypto operations.

  These tests use fixed test vectors that must produce identical results
  in both the Elixir (server) and Flutter (client) implementations.

  Test vectors cover:
  - X25519 ECDH key exchange
  - HKDF-SHA256 key derivation
  - ChaCha20-Poly1305 authenticated encryption

  The Flutter equivalent tests are in:
  player/test/core/crypto/cross_platform_test.dart
  """

  use ExUnit.Case, async: true

  alias Mydia.Crypto

  # ============================================================================
  # Test Vector Constants
  # These values are used by both Elixir and Flutter tests.
  # Changing these values requires updating the Flutter tests as well.
  # ============================================================================

  # X25519 key pairs (from RFC 7748 test vectors)
  @alice_private_key Base.decode64!("dwdtCnMYpX08FsFyUbJmRd9ML4frwJkqsXf7pR25LCo=")
  @alice_public_key Base.decode64!("hSDwCYkwp1R0i33ctD73Wg2/Og0mOBr066SpjqqbTmo=")
  @bob_private_key Base.decode64!("XasIfmJKikt54X+Lg4AO5m87sSkmGLb9HC+LJ/+I4Os=")
  @bob_public_key Base.decode64!("3p7bfXt9wbTTW2HC7OQ1Nz+DQ8hbeGdNrfx+FG+IK08=")

  # Expected shared secret from X25519 ECDH
  @expected_shared_secret Base.decode64!("Sl2dW6TOLeFyjjv0gDUPJeB+IclH0Z4zdvCbPB4WF0I=")

  # Expected session key after HKDF-SHA256 derivation
  @expected_session_key Base.decode64!("O4JgYEVzaUyxG0tuQz5E1ptxX2qcdrjbrY43QLM+xQw=")

  # ChaCha20-Poly1305 encryption test vectors
  @test_nonce Base.decode64!("AAAAAAAAAAAAAAAB")
  @test_plaintext "Hello from Elixir to Flutter!"
  @expected_ciphertext Base.decode64!("FR87tXgCzdKEwRwego00v8WLjSpKQEpYhstK60k=")
  @expected_mac Base.decode64!("dKLBE7tTUEB2tIOy3B9qHw==")

  # Additional HKDF test vectors
  @hkdf_test_ikm_1 :binary.copy(<<0x01>>, 32)
  @hkdf_expected_key_1 Base.decode64!("qw1cYyAG63Ob8gMI9lgxhE+ejdxGIrrGDYsFwnOiwFQ=")

  @hkdf_test_ikm_2 Base.decode16!(
                     "0102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F20"
                   )
  @hkdf_expected_key_2 Base.decode64!("pYVxdJkM3ZsEWanSBDNfNdztu81/Zoul8+6vfk5LgZk=")

  # Additional ChaCha20-Poly1305 test vectors
  @test_key_1 Base.decode64!("qw1cYyAG63Ob8gMI9lgxhE+ejdxGIrrGDYsFwnOiwFQ=")
  @test_nonce_1 Base.decode64!("AAAAAAAAAAAAAAAB")
  @test_plaintext_1 "Hello, World!"
  @expected_ciphertext_1 Base.decode64!("sx9ZlIqKK5vS9Afj+A==")
  @expected_mac_1 Base.decode64!("YfqcJ3IcQw0+Lrw9MnwjtA==")

  @test_nonce_3 Base.decode64!("ECAwQFBgcICQoLDA")
  @test_plaintext_3 "Test message for cross-platform compatibility"
  @expected_ciphertext_3 Base.decode64!(
                           "bNRLMKmWw9+wMYfZgD5uqFWt6GY/6HPy1CHJCLKmRrq60m6rNMP9xv6wT5Ei"
                         )
  @expected_mac_3 Base.decode64!("LEic0kwn4OHWu5n6Km3wnw==")

  describe "X25519 ECDH key exchange" do
    test "generates correct public key from private key" do
      # Generate public key from Alice's private key
      {public_key, _private_key} = :crypto.generate_key(:ecdh, :x25519, @alice_private_key)

      assert public_key == @alice_public_key
    end

    test "computes correct shared secret (Alice's perspective)" do
      # Alice computes shared secret using her private key and Bob's public key
      shared_secret = :crypto.compute_key(:ecdh, @bob_public_key, @alice_private_key, :x25519)

      assert shared_secret == @expected_shared_secret
    end

    test "computes correct shared secret (Bob's perspective)" do
      # Bob computes shared secret using his private key and Alice's public key
      shared_secret = :crypto.compute_key(:ecdh, @alice_public_key, @bob_private_key, :x25519)

      assert shared_secret == @expected_shared_secret
    end

    test "both parties derive identical shared secret" do
      alice_secret = :crypto.compute_key(:ecdh, @bob_public_key, @alice_private_key, :x25519)
      bob_secret = :crypto.compute_key(:ecdh, @alice_public_key, @bob_private_key, :x25519)

      assert alice_secret == bob_secret
      assert alice_secret == @expected_shared_secret
    end
  end

  describe "HKDF-SHA256 key derivation" do
    test "derives correct session key from shared secret" do
      # Use the Crypto module's derive_session_key function
      # We need to directly call the internal HKDF implementation since
      # derive_session_key expects raw keys, not pre-computed shared secret

      # Manual HKDF computation to match the module's implementation
      salt = :binary.copy(<<0>>, 32)
      info = "mydia-session-key"

      # HKDF Extract
      prk = :crypto.mac(:hmac, :sha256, salt, @expected_shared_secret)

      # HKDF Expand
      session_key = :crypto.mac(:hmac, :sha256, prk, info <> <<1::8>>)

      assert session_key == @expected_session_key
    end

    test "derives correct key with test vector 1 (all 0x01 bytes)" do
      salt = :binary.copy(<<0>>, 32)
      info = "mydia-session-key"

      prk = :crypto.mac(:hmac, :sha256, salt, @hkdf_test_ikm_1)
      derived_key = :crypto.mac(:hmac, :sha256, prk, info <> <<1::8>>)

      assert derived_key == @hkdf_expected_key_1
    end

    test "derives correct key with test vector 2 (sequential bytes)" do
      salt = :binary.copy(<<0>>, 32)
      info = "mydia-session-key"

      prk = :crypto.mac(:hmac, :sha256, salt, @hkdf_test_ikm_2)
      derived_key = :crypto.mac(:hmac, :sha256, prk, info <> <<1::8>>)

      assert derived_key == @hkdf_expected_key_2
    end

    test "full key exchange produces expected session key" do
      # Simulate full key exchange using the Crypto module
      session_key = Crypto.derive_session_key(@alice_private_key, @bob_public_key)

      assert session_key == @expected_session_key
    end
  end

  describe "ChaCha20-Poly1305 encryption" do
    test "encrypts to expected ciphertext and MAC with test vector 1" do
      {ciphertext, mac} =
        :crypto.crypto_one_time_aead(
          :chacha20_poly1305,
          @test_key_1,
          @test_nonce_1,
          @test_plaintext_1,
          <<>>,
          true
        )

      assert ciphertext == @expected_ciphertext_1
      assert mac == @expected_mac_1
    end

    test "encrypts to expected ciphertext and MAC with test vector 3" do
      {ciphertext, mac} =
        :crypto.crypto_one_time_aead(
          :chacha20_poly1305,
          @test_key_1,
          @test_nonce_3,
          @test_plaintext_3,
          <<>>,
          true
        )

      assert ciphertext == @expected_ciphertext_3
      assert mac == @expected_mac_3
    end

    test "encrypts to expected ciphertext and MAC with E2E session key" do
      {ciphertext, mac} =
        :crypto.crypto_one_time_aead(
          :chacha20_poly1305,
          @expected_session_key,
          @test_nonce,
          @test_plaintext,
          <<>>,
          true
        )

      assert ciphertext == @expected_ciphertext
      assert mac == @expected_mac
    end

    test "decrypts test vector ciphertext correctly" do
      plaintext =
        :crypto.crypto_one_time_aead(
          :chacha20_poly1305,
          @expected_session_key,
          @test_nonce,
          @expected_ciphertext,
          <<>>,
          @expected_mac,
          false
        )

      assert plaintext == @test_plaintext
    end

    test "decrypts test vector 1 correctly" do
      plaintext =
        :crypto.crypto_one_time_aead(
          :chacha20_poly1305,
          @test_key_1,
          @test_nonce_1,
          @expected_ciphertext_1,
          <<>>,
          @expected_mac_1,
          false
        )

      assert plaintext == @test_plaintext_1
    end

    test "decrypts test vector 3 correctly" do
      plaintext =
        :crypto.crypto_one_time_aead(
          :chacha20_poly1305,
          @test_key_1,
          @test_nonce_3,
          @expected_ciphertext_3,
          <<>>,
          @expected_mac_3,
          false
        )

      assert plaintext == @test_plaintext_3
    end

    test "fails decryption with wrong MAC" do
      # Flip a bit in the MAC
      <<first_byte, rest::binary>> = @expected_mac
      wrong_mac = <<Bitwise.bxor(first_byte, 1), rest::binary>>

      result =
        :crypto.crypto_one_time_aead(
          :chacha20_poly1305,
          @expected_session_key,
          @test_nonce,
          @expected_ciphertext,
          <<>>,
          wrong_mac,
          false
        )

      assert result == :error
    end

    test "fails decryption with wrong key" do
      wrong_key = :binary.copy(<<0x00>>, 32)

      result =
        :crypto.crypto_one_time_aead(
          :chacha20_poly1305,
          wrong_key,
          @test_nonce,
          @expected_ciphertext,
          <<>>,
          @expected_mac,
          false
        )

      assert result == :error
    end
  end

  describe "end-to-end cross-platform flow" do
    test "full flow: key exchange -> key derivation -> encryption" do
      # Step 1: Key Exchange (simulate Alice and Bob exchanging public keys)
      alice_shared = :crypto.compute_key(:ecdh, @bob_public_key, @alice_private_key, :x25519)
      bob_shared = :crypto.compute_key(:ecdh, @alice_public_key, @bob_private_key, :x25519)

      assert alice_shared == bob_shared

      # Step 2: Key Derivation (both derive session key)
      alice_session = Crypto.derive_session_key(@alice_private_key, @bob_public_key)
      bob_session = Crypto.derive_session_key(@bob_private_key, @alice_public_key)

      assert alice_session == bob_session
      assert alice_session == @expected_session_key

      # Step 3: Encryption (Alice encrypts a message)
      {ciphertext, mac} =
        :crypto.crypto_one_time_aead(
          :chacha20_poly1305,
          alice_session,
          @test_nonce,
          @test_plaintext,
          <<>>,
          true
        )

      # Step 4: Decryption (Bob decrypts the message)
      plaintext =
        :crypto.crypto_one_time_aead(
          :chacha20_poly1305,
          bob_session,
          @test_nonce,
          ciphertext,
          <<>>,
          mac,
          false
        )

      assert plaintext == @test_plaintext
    end

    test "using high-level Crypto module for encryption/decryption" do
      # Derive session keys
      alice_session = Crypto.derive_session_key(@alice_private_key, @bob_public_key)
      bob_session = Crypto.derive_session_key(@bob_private_key, @alice_public_key)

      assert alice_session == bob_session

      # Alice encrypts (using random nonce)
      encrypted = Crypto.encrypt("Secret cross-platform message", alice_session)

      # Bob decrypts
      assert {:ok, "Secret cross-platform message"} =
               Crypto.decrypt(encrypted.ciphertext, encrypted.nonce, encrypted.mac, bob_session)
    end
  end

  describe "base64 encoding compatibility" do
    test "all test vectors are valid base64 and correct sizes" do
      # X25519 keys are 32 bytes
      assert byte_size(@alice_private_key) == 32
      assert byte_size(@alice_public_key) == 32
      assert byte_size(@bob_private_key) == 32
      assert byte_size(@bob_public_key) == 32

      # Shared secret and session key are 32 bytes
      assert byte_size(@expected_shared_secret) == 32
      assert byte_size(@expected_session_key) == 32

      # Nonce is 12 bytes
      assert byte_size(@test_nonce) == 12

      # MAC is 16 bytes
      assert byte_size(@expected_mac) == 16
    end

    test "ciphertext length matches plaintext length" do
      # ChaCha20 is a stream cipher, so ciphertext length equals plaintext length
      assert byte_size(@expected_ciphertext) == byte_size(@test_plaintext)
    end
  end
end
