defmodule Mydia.RemoteAccess do
  @moduledoc """
  Context module for remote access functionality.
  Manages instance configuration and device pairing for remote access.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Mydia.Repo
  alias Mydia.RemoteAccess.{Config, DirectUrls, PairingClaim, RemoteDevice}

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
    # Generate a new X25519 keypair
    {public_key, private_key} = Mydia.Crypto.generate_keypair()

    # Get the application secret for encryption
    app_secret = get_app_secret()

    # Encrypt the private key (returns a 60-byte binary blob)
    # Format: <<nonce::binary-12, ciphertext::binary-32, mac::binary-16>>
    encrypted_blob = Mydia.Crypto.encrypt_private_key(private_key, app_secret)

    # Generate a unique instance ID
    instance_id = Ecto.UUID.generate()

    # Create the config with the keypair
    # Note: relay_url is read from METADATA_RELAY_URL env var at runtime
    %Config{}
    |> Config.changeset(%{
      instance_id: instance_id,
      static_public_key: public_key,
      static_private_key_encrypted: encrypted_blob,
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
        # Get the application secret
        app_secret = get_app_secret()

        # Decrypt the private key (supports both old and new formats)
        Mydia.Crypto.decrypt_private_key(config.static_private_key_encrypted, app_secret)
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
  Gets an active (non-revoked) device by ID, preloading the user.

  Returns `{:ok, device}` if found and active.
  Returns `{:error, :not_found}` if device doesn't exist.
  Returns `{:error, :revoked}` if device is revoked.
  """
  @spec get_active_device(String.t()) :: {:ok, RemoteDevice.t()} | {:error, :not_found | :revoked}
  def get_active_device(device_id) do
    case Repo.get(RemoteDevice, device_id) |> Repo.preload(:user) do
      nil ->
        {:error, :not_found}

      device ->
        if RemoteDevice.revoked?(device) do
          {:error, :revoked}
        else
          {:ok, device}
        end
    end
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
    case device
         |> RemoteDevice.revoke_changeset()
         |> Repo.update() do
      {:ok, updated_device} = result ->
        # Publish device status change event
        publish_device_event(updated_device, :revoked)
        result

      error ->
        error
    end
  end

  @doc """
  Deletes a device completely.
  """
  def delete_device(device) do
    case Repo.delete(device) do
      {:ok, deleted_device} = result ->
        # Publish device status change event
        publish_device_event(deleted_device, :deleted)
        result

      error ->
        error
    end
  end

  # Claim code management

  @doc """
  Generates a new pairing claim code for a user.
  The code expires after 5 minutes.

  This function:
  1. Requests a claim code from the relay service
  2. Creates a local claim record with the returned code

  Returns {:ok, claim} if successful, {:error, reason} otherwise.
  """
  def generate_claim_code(user_id) do
    Logger.debug("Requesting pairing claim from relay for user_id=#{user_id}")

    # Request claim code from relay - it generates and returns the code
    case Mydia.RemoteAccess.Relay.request_claim(user_id, 300) do
      {:ok, code, expires_at_str} ->
        Logger.debug("Received claim code from relay: #{code}")

        # Parse the expires_at from ISO8601 string
        {:ok, expires_at, _} = DateTime.from_iso8601(expires_at_str)

        # Create local claim record with the code from relay
        %PairingClaim{}
        |> PairingClaim.changeset_with_code(%{
          user_id: user_id,
          code: code,
          expires_at: expires_at
        })
        |> Repo.insert()

      {:error, :not_running} ->
        Logger.warning("Relay process not running")
        {:error, :relay_not_connected}

      {:error, :timeout} ->
        Logger.warning("Relay request timed out")
        {:error, :relay_timeout}

      {:error, reason} ->
        Logger.error("Relay request failed: #{inspect(reason)}")
        {:error, {:relay_error, reason}}
    end
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
  # This only cleans user input - it doesn't re-add dashes since relay generates
  # codes without dashes and stores them as-is
  defp normalize_code(code) do
    code
    |> String.replace(~r/[\s-]/, "")
    |> String.upcase()
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

  @doc """
  Updates the instance's direct URLs and certificate fingerprint.
  This should be called when the instance's reachable URLs or certificate changes.

  ## Parameters

  - `direct_urls` - List of direct URL strings
  - `cert_fingerprint` - Certificate fingerprint (hex string with colons)
  - `notify_relay?` - Whether to notify the relay service (default: true)

  ## Examples

      iex> update_direct_urls(["https://192-168-1-100.sslip.io:4000"], "A1:B2:C3:...", true)
      {:ok, config}

  """
  def update_direct_urls(direct_urls, cert_fingerprint, notify_relay? \\ true)
      when is_list(direct_urls) and is_binary(cert_fingerprint) do
    # Update the config
    with {:ok, config} <-
           upsert_config(%{
             direct_urls: direct_urls,
             cert_fingerprint: cert_fingerprint
           }) do
      # Notify the relay connection if requested
      if notify_relay? do
        case Mydia.RemoteAccess.Relay.update_direct_urls(direct_urls) do
          :ok -> {:ok, config}
          error -> error
        end
      else
        {:ok, config}
      end
    end
  end

  @doc """
  Refreshes the instance's direct URLs by auto-detecting them.
  This detects all available network interfaces and updates the stored URLs.

  Returns {:ok, config} with the updated configuration, or {:error, reason}.

  ## Examples

      iex> refresh_direct_urls()
      {:ok, %Config{direct_urls: ["https://192-168-1-100.sslip.io:4000"], ...}}

  """
  def refresh_direct_urls do
    # Auto-detect direct URLs
    direct_urls = Mydia.RemoteAccess.DirectUrls.detect_all()

    # Ensure certificate exists and get fingerprint
    case Mydia.RemoteAccess.Certificates.ensure_certificate() do
      {:ok, _cert_path, _key_path, fingerprint} ->
        update_direct_urls(direct_urls, fingerprint)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Updates the instance's direct URLs with the relay service.
  This should be called when the instance's reachable URLs change
  (e.g., after network configuration changes).

  DEPRECATED: Use `update_direct_urls/3` instead.
  """
  def update_relay_urls(direct_urls) when is_list(direct_urls) do
    # Update the config
    with {:ok, _config} <- upsert_config(%{direct_urls: direct_urls}),
         # Notify the relay connection
         :ok <- Mydia.RemoteAccess.Relay.update_direct_urls(direct_urls) do
      {:ok, direct_urls}
    end
  end

  @doc """
  Updates the public port used for public IP URLs.

  This port is used when generating sslip.io URLs from the detected public IP.
  Useful when your external port differs from internal port (e.g., NAT port forwarding).

  Pass `nil` to clear the override and use the default external_port.
  """
  def update_public_port(nil) do
    case get_config() do
      nil ->
        {:error, :not_configured}

      config ->
        case config
             |> Config.update_public_port_changeset(nil)
             |> Repo.update() do
          {:ok, updated_config} ->
            # Clear the public IP cache to regenerate URLs with new port
            DirectUrls.clear_public_ip_cache()
            {:ok, updated_config}

          {:error, _} = error ->
            error
        end
    end
  end

  def update_public_port(port) when is_integer(port) and port > 0 and port < 65536 do
    case get_config() do
      nil ->
        {:error, :not_configured}

      config ->
        case config
             |> Config.update_public_port_changeset(port)
             |> Repo.update() do
          {:ok, updated_config} ->
            # Clear the public IP cache to regenerate URLs with new port
            DirectUrls.clear_public_ip_cache()
            {:ok, updated_config}

          {:error, _} = error ->
            error
        end
    end
  end

  def update_public_port(_), do: {:error, :invalid_port}

  @doc """
  Manually triggers a relay reconnection.
  Useful for troubleshooting or forcing re-registration.
  """
  def reconnect_relay do
    Mydia.RemoteAccess.Relay.reconnect()
  end

  @doc """
  Starts the relay connection process.
  Called when remote access is enabled.
  Returns :ok if started successfully, {:error, reason} otherwise.
  """
  def start_relay do
    # Check if already running to avoid duplicate processes
    if Process.whereis(Mydia.RemoteAccess.Relay) do
      :ok
    else
      case DynamicSupervisor.start_child(
             {:via, Registry, {Mydia.DynamicSupervisorRegistry, :relay}},
             Mydia.RemoteAccess.Relay
           ) do
        {:ok, _pid} ->
          Logger.info("Relay service started")
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, reason} ->
          Logger.error("Failed to start relay service: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Stops the relay connection process.
  Called when remote access is disabled.
  Returns :ok.
  """
  def stop_relay do
    # Find the relay process
    case Process.whereis(Mydia.RemoteAccess.Relay) do
      nil ->
        :ok

      pid ->
        DynamicSupervisor.terminate_child(
          {:via, Registry, {Mydia.DynamicSupervisorRegistry, :relay}},
          pid
        )

        Logger.info("Relay service stopped")
        :ok
    end
  end

  # Subscription helpers

  @doc """
  Publishes a device status change event to GraphQL subscriptions.
  """
  def publish_device_event(device, event_type)
      when event_type in [:connected, :disconnected, :revoked, :deleted] do
    event_payload = %{
      device: format_device_for_subscription(device),
      event: event_type
    }

    Absinthe.Subscription.publish(
      MydiaWeb.Endpoint,
      event_payload,
      device_status_changed: "device_status:#{device.user_id}"
    )
  end

  # Format device struct for subscription payload
  defp format_device_for_subscription(device) do
    %{
      id: device.id,
      device_name: device.device_name,
      platform: device.platform,
      last_seen_at: device.last_seen_at,
      revoked_at: device.revoked_at,
      inserted_at: device.inserted_at
    }
  end
end
