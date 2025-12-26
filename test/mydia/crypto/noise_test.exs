defmodule Mydia.Crypto.NoiseTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias Mydia.Crypto.Noise

  describe "generate_keypair/0" do
    test "generates a valid Curve25519 keypair" do
      {public_key, private_key} = Noise.generate_keypair()

      assert is_binary(public_key)
      assert is_binary(private_key)
      assert byte_size(public_key) == 32
      assert byte_size(private_key) == 32
    end

    test "generates unique keypairs on each call" do
      {public1, private1} = Noise.generate_keypair()
      {public2, private2} = Noise.generate_keypair()

      refute public1 == public2
      refute private1 == private2
    end
  end

  describe "encrypt_private_key/2 and decrypt_private_key/2" do
    setup do
      {_public, private} = Noise.generate_keypair()
      app_secret = :crypto.strong_rand_bytes(32)

      %{private_key: private, app_secret: app_secret}
    end

    test "encrypts and decrypts a private key successfully", %{
      private_key: private_key,
      app_secret: app_secret
    } do
      encrypted = Noise.encrypt_private_key(private_key, app_secret)

      assert is_map(encrypted)
      assert Map.has_key?(encrypted, :ciphertext)
      assert Map.has_key?(encrypted, :nonce)
      assert is_binary(encrypted.ciphertext)
      assert is_integer(encrypted.nonce)

      {:ok, decrypted} = Noise.decrypt_private_key(encrypted, app_secret)
      assert decrypted == private_key
    end

    test "encrypted data is different from plaintext", %{
      private_key: private_key,
      app_secret: app_secret
    } do
      encrypted = Noise.encrypt_private_key(private_key, app_secret)

      refute encrypted.ciphertext == private_key
    end

    test "produces different ciphertexts for same plaintext (due to random nonce)", %{
      private_key: private_key,
      app_secret: app_secret
    } do
      encrypted1 = Noise.encrypt_private_key(private_key, app_secret)
      encrypted2 = Noise.encrypt_private_key(private_key, app_secret)

      refute encrypted1.ciphertext == encrypted2.ciphertext
      refute encrypted1.nonce == encrypted2.nonce

      {:ok, decrypted1} = Noise.decrypt_private_key(encrypted1, app_secret)
      {:ok, decrypted2} = Noise.decrypt_private_key(encrypted2, app_secret)

      assert decrypted1 == private_key
      assert decrypted2 == private_key
    end

    test "decryption fails with wrong secret key", %{
      private_key: private_key,
      app_secret: app_secret
    } do
      encrypted = Noise.encrypt_private_key(private_key, app_secret)
      wrong_secret = :crypto.strong_rand_bytes(32)

      assert {:error, :decryption_failed} = Noise.decrypt_private_key(encrypted, wrong_secret)
    end

    test "decryption fails with tampered ciphertext", %{
      private_key: private_key,
      app_secret: app_secret
    } do
      encrypted = Noise.encrypt_private_key(private_key, app_secret)

      # Tamper with the ciphertext by flipping a bit
      <<first_byte, rest::binary>> = encrypted.ciphertext
      tampered_ciphertext = <<bxor(first_byte, 1), rest::binary>>
      tampered = %{encrypted | ciphertext: tampered_ciphertext}

      assert {:error, :decryption_failed} = Noise.decrypt_private_key(tampered, app_secret)
    end
  end
end
