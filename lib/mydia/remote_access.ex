defmodule Mydia.RemoteAccess do
  @moduledoc """
  Context module for remote access functionality.
  Manages instance configuration and device pairing for remote access.
  """

  import Ecto.Query, warn: false
  alias Mydia.Repo
  alias Mydia.RemoteAccess.{Config, PairingClaim, RemoteDevice}

  # Config management

  @doc """
  Initializes the instance keypair and generates a unique instance ID.

  This function should be called when remote access is first enabled.
  It generates a new Noise protocol keypair, encrypts the private key using
  the application secret, and stores both keys along with a unique instance ID.

  Returns {:ok, config} with the initialized configuration, or {:error, changeset}
  if the operation fails.

  ## Security Notes

  - The private key is encrypted using the application's secret_key_base
  - The instance ID is a UUID v4 that uniquely identifies this Mydia instance
  - This should only be called once per instance, typically when enabling remote access

  ## Examples

      iex> {:ok, config} = Mydia.RemoteAccess.initialize_keypair()
      iex> byte_size(config.static_public_key)
      32
      iex> is_binary(config.static_private_key_encrypted)
      true
      iex> is_binary(config.instance_id)
      true

  """
  def initialize_keypair do
    # Generate a new Noise protocol keypair
    {public_key, private_key} = Mydia.Crypto.Noise.generate_keypair()

    # Get the application secret for encryption
    app_secret = get_app_secret()

    # Encrypt the private key
    encrypted = Mydia.Crypto.Noise.encrypt_private_key(private_key, app_secret)

    # Generate a unique instance ID
    instance_id = Ecto.UUID.generate()

    # Encode the encrypted data for storage
    # We store both the ciphertext and nonce in a single binary field
    # Format: <<nonce::64, ciphertext::binary>>
    encrypted_blob = <<encrypted.nonce::64>> <> encrypted.ciphertext

    # Create the config with the keypair
    %Config{}
    |> Config.changeset(%{
      instance_id: instance_id,
      static_public_key: public_key,
      static_private_key_encrypted: encrypted_blob,
      relay_url: "https://relay.mydia.app",
      enabled: false
    })
    |> Repo.insert()
  end

  @doc """
  Gets the public key for the instance.

  Returns the instance's static public key, which can be safely shared with clients
  for configuration and pairing.

  Returns the public key as a 32-byte binary, or nil if not configured.

  ## Examples

      iex> Mydia.RemoteAccess.get_public_key()
      <<1, 2, 3, ...>>  # 32-byte public key

  """
  def get_public_key do
    case get_config() do
      nil -> nil
      config -> config.static_public_key
    end
  end

  @doc """
  Gets the decrypted private key for the instance.

  This function decrypts the stored private key using the application secret.
  It should only be used internally for Noise protocol operations.

  **Security Warning**: This returns the raw private key. Never log or expose
  this value outside of secure cryptographic operations.

  Returns {:ok, private_key} or {:error, reason}.

  ## Examples

      iex> {:ok, private_key} = Mydia.RemoteAccess.get_private_key()
      iex> byte_size(private_key)
      32

  """
  def get_private_key do
    case get_config() do
      nil ->
        {:error, :not_configured}

      config ->
        # Extract nonce and ciphertext from the stored blob
        <<nonce::64, ciphertext::binary>> = config.static_private_key_encrypted

        # Get the application secret
        app_secret = get_app_secret()

        # Decrypt the private key
        encrypted_data = %{ciphertext: ciphertext, nonce: nonce}
        Mydia.Crypto.Noise.decrypt_private_key(encrypted_data, app_secret)
    end
  end

  # Private helper to get the application secret key
  # Derives a 32-byte key from the secret_key_base
  defp get_app_secret do
    secret_key_base = Application.get_env(:mydia, MydiaWeb.Endpoint)[:secret_key_base]

    # Use the first 32 bytes of the secret_key_base
    # In production, secret_key_base is at least 64 bytes
    :crypto.hash(:sha256, secret_key_base)
  end

  @doc """
  Gets the remote access configuration.
  Returns nil if not configured.
  """
  def get_config do
    Repo.one(Config)
  end

  @doc """
  Gets the remote access configuration, raising if not found.
  """
  def get_config! do
    case get_config() do
      nil -> raise Ecto.NoResultsError, queryable: Config
      config -> config
    end
  end

  @doc """
  Creates or updates the remote access configuration.
  Since there should only be one config, this upserts.
  """
  def upsert_config(attrs) do
    case get_config() do
      nil ->
        %Config{}
        |> Config.changeset(attrs)
        |> Repo.insert()

      config ->
        config
        |> Config.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Enables or disables remote access.
  """
  def toggle_remote_access(enabled) when is_boolean(enabled) do
    case get_config() do
      nil ->
        {:error, :not_configured}

      config ->
        config
        |> Config.toggle_enabled_changeset(enabled)
        |> Repo.update()
    end
  end

  # Device management

  @doc """
  Lists all paired devices for a user.
  """
  def list_devices(user_id) do
    RemoteDevice
    |> where([d], d.user_id == ^user_id)
    |> order_by([d], desc: d.inserted_at)
    |> Repo.all()
  end

  @doc """
  Lists all active (non-revoked) devices for a user.
  """
  def list_active_devices(user_id) do
    RemoteDevice
    |> where([d], d.user_id == ^user_id and is_nil(d.revoked_at))
    |> order_by([d], desc: d.last_seen_at)
    |> Repo.all()
  end

  @doc """
  Gets a device by ID.
  """
  def get_device(id) do
    Repo.get(RemoteDevice, id)
  end

  @doc """
  Gets a device by ID, raising if not found.
  """
  def get_device!(id) do
    Repo.get!(RemoteDevice, id)
  end

  @doc """
  Gets a device by token hash.
  """
  def get_device_by_token_hash(token_hash) do
    Repo.get_by(RemoteDevice, token_hash: token_hash)
  end

  @doc """
  Creates a new device pairing.
  """
  def create_device(attrs) do
    %RemoteDevice{}
    |> RemoteDevice.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates the last seen timestamp for a device.
  """
  def touch_device(device) do
    device
    |> RemoteDevice.seen_changeset()
    |> Repo.update()
  end

  @doc """
  Revokes a device, preventing future access.
  """
  def revoke_device(device) do
    device
    |> RemoteDevice.revoke_changeset()
    |> Repo.update()
  end

  @doc """
  Deletes a device completely.
  """
  def delete_device(device) do
    Repo.delete(device)
  end

  # Claim code management

  @doc """
  Generates a new pairing claim code for a user.
  The code expires after 5 minutes.
  """
  def generate_claim_code(user_id) do
    %PairingClaim{}
    |> PairingClaim.create_changeset(%{user_id: user_id})
    |> Repo.insert()
  end

  @doc """
  Validates a claim code with rate limiting.
  Returns {:ok, claim} if the code is valid (exists, not expired, not used).
  Returns {:error, reason} otherwise.

  Optional `ip_address` parameter enables rate limiting.
  """
  def validate_claim_code(code, opts \\ []) do
    ip_address = Keyword.get(opts, :ip_address)

    # Check rate limit if IP address is provided
    if ip_address do
      case Mydia.RemoteAccess.ClaimRateLimiter.check_rate_limit(ip_address) do
        :ok ->
          do_validate_claim_code(code, ip_address)

        {:error, :rate_limited} = error ->
          error
      end
    else
      do_validate_claim_code(code, nil)
    end
  end

  defp do_validate_claim_code(code, ip_address) do
    code = normalize_code(code)

    result =
      case get_claim_by_code(code) do
        nil ->
          {:error, :not_found}

        claim ->
          cond do
            PairingClaim.used?(claim) ->
              {:error, :already_used}

            PairingClaim.expired?(claim) ->
              {:error, :expired}

            true ->
              {:ok, claim}
          end
      end

    # Record failed attempt if IP address is provided
    if ip_address do
      case result do
        {:ok, _claim} ->
          Mydia.RemoteAccess.ClaimRateLimiter.reset_rate_limit(ip_address)

        {:error, _reason} ->
          Mydia.RemoteAccess.ClaimRateLimiter.record_failed_attempt(ip_address)
      end
    end

    result
  end

  @doc """
  Consumes a claim code, marking it as used and linking it to a device.
  Returns {:ok, claim} if successful.
  Returns {:error, reason} if the claim is invalid.
  """
  def consume_claim_code(code, device_id) do
    code = normalize_code(code)

    with {:ok, claim} <- validate_claim_code(code) do
      claim
      |> PairingClaim.consume_changeset(device_id)
      |> Repo.update()
    end
  end

  @doc """
  Cleans up expired claim codes.
  Deletes all claims that have expired and have not been used.
  Returns {:ok, count} where count is the number of deleted claims.
  """
  def cleanup_expired_claims do
    now = DateTime.utc_now()

    {count, _} =
      PairingClaim
      |> where([c], c.expires_at < ^now)
      |> Repo.delete_all()

    {:ok, count}
  end

  @doc """
  Gets a claim by its code.
  Returns nil if not found.
  """
  def get_claim_by_code(code) do
    code = normalize_code(code)
    Repo.get_by(PairingClaim, code: code)
  end

  @doc """
  Lists all active (non-expired, non-used) claims for a user.
  """
  def list_active_claims(user_id) do
    now = DateTime.utc_now()

    PairingClaim
    |> where([c], c.user_id == ^user_id)
    |> where([c], is_nil(c.used_at))
    |> where([c], c.expires_at > ^now)
    |> order_by([c], desc: c.inserted_at)
    |> Repo.all()
  end

  # Normalize claim code by removing whitespace and dashes, converting to uppercase
  defp normalize_code(code) do
    code
    |> String.replace(~r/[\s-]/, "")
    |> String.upcase()
    |> then(fn normalized ->
      # Re-add the dash in the middle for consistency with stored format
      half = div(String.length(normalized), 2)

      if half > 0 do
        {first, second} = String.split_at(normalized, half)
        "#{first}-#{second}"
      else
        normalized
      end
    end)
  end

  # Relay service management

  @doc """
  Gets the status of the relay connection.

  Returns {:ok, status} where status is a map with:
  - :connected - boolean indicating if connected to relay
  - :registered - boolean indicating if registered with relay
  - :instance_id - the instance identifier

  Returns {:error, reason} if relay is not running or unavailable.
  """
  def relay_status do
    Mydia.RemoteAccess.Relay.status()
  end

  @doc """
  Checks if the relay service is available and connected.
  Returns true if relay is connected and registered, false otherwise.
  """
  def relay_available? do
    case relay_status() do
      {:ok, %{connected: true, registered: true}} -> true
      _ -> false
    end
  end
end
