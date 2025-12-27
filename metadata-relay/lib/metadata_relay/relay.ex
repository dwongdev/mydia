defmodule MetadataRelay.Relay do
  @moduledoc """
  Context module for remote access relay functionality.

  This module handles:
  - Instance registration and management
  - Heartbeat/presence updates
  - Claim code creation and redemption
  - Connection info lookup for clients

  The relay enables Mydia instances to be discoverable and reachable
  even when behind NAT, using claim codes for secure device pairing.
  """

  import Ecto.Query
  alias MetadataRelay.Repo
  alias MetadataRelay.Relay.{Instance, Claim}

  # ============================================================================
  # Instance Management
  # ============================================================================

  @doc """
  Registers a new instance with the relay.

  ## Parameters
  - `attrs` - Map containing:
    - `:instance_id` - Unique instance identifier (required)
    - `:public_key` - 32-byte Curve25519 public key (required)
    - `:direct_urls` - List of direct URLs (optional)

  Returns `{:ok, instance}` or `{:error, changeset}`.
  """
  def register_instance(attrs) do
    %Instance{}
    |> Instance.create_changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:public_key, :direct_urls, :updated_at]},
      conflict_target: :instance_id,
      returning: true
    )
  end

  @doc """
  Gets an instance by its instance_id.
  Returns `nil` if not found.
  """
  def get_instance(instance_id) do
    Repo.get_by(Instance, instance_id: instance_id)
  end

  @doc """
  Gets an instance by its instance_id.
  Raises if not found.
  """
  def get_instance!(instance_id) do
    Repo.get_by!(Instance, instance_id: instance_id)
  end

  @doc """
  Updates instance heartbeat/presence.

  ## Parameters
  - `instance` - The instance to update
  - `attrs` - Map containing:
    - `:direct_urls` - Updated list of direct URLs (optional)

  Returns `{:ok, instance}` or `{:error, changeset}`.
  """
  def update_heartbeat(instance, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    attrs = Map.merge(attrs, %{last_seen_at: now, online: true})

    instance
    |> Instance.heartbeat_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Sets an instance as online.
  Called when WebSocket connection is established.
  """
  def set_online(instance) do
    instance
    |> Instance.online_changeset(true)
    |> Repo.update()
  end

  @doc """
  Sets an instance as offline.
  Called when WebSocket connection is lost.
  """
  def set_offline(instance) do
    instance
    |> Instance.online_changeset(false)
    |> Repo.update()
  end

  @doc """
  Sets an instance as offline by instance_id.
  Returns `{:ok, instance}`, `{:error, changeset}`, or `{:error, :not_found}`.
  """
  def set_offline_by_instance_id(instance_id) do
    case get_instance(instance_id) do
      nil -> {:error, :not_found}
      instance -> set_offline(instance)
    end
  end

  @doc """
  Gets connection info for an instance.
  Returns information needed by clients to connect.
  """
  def get_connection_info(instance_id) do
    case get_instance(instance_id) do
      nil ->
        {:error, :not_found}

      instance ->
        {:ok,
         %{
           instance_id: instance.instance_id,
           public_key: Base.encode64(instance.public_key),
           direct_urls: instance.direct_urls,
           online: instance.online,
           last_seen_at: instance.last_seen_at
         }}
    end
  end

  # ============================================================================
  # Claim Code Management
  # ============================================================================

  @doc """
  Creates a new claim code for an instance.

  ## Parameters
  - `instance` - The instance creating the claim
  - `user_id` - The user ID associated with this claim
  - `opts` - Options:
    - `:ttl_seconds` - Custom TTL (default: 300)
    - `:code` - Custom code (default: auto-generated)

  Returns `{:ok, claim}` or `{:error, changeset}`.
  """
  def create_claim(instance, user_id, opts \\ []) do
    code = Keyword.get(opts, :code, Claim.generate_code())
    ttl = Keyword.get(opts, :ttl_seconds, 300)

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(ttl, :second)
      |> DateTime.truncate(:second)

    attrs = %{
      code: String.upcase(code),
      user_id: user_id,
      instance_id: instance.id,
      expires_at: expires_at
    }

    %Claim{}
    |> Claim.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Redeems a claim code.

  Returns the instance info if the code is valid, allowing
  the client to initiate a connection.

  ## Parameters
  - `code` - The claim code to redeem

  Returns `{:ok, claim_info}` or `{:error, reason}`.
  """
  def redeem_claim(code) do
    code = String.upcase(code)

    query =
      from c in Claim,
        where: c.code == ^code,
        preload: [:instance]

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      claim ->
        cond do
          Claim.consumed?(claim) ->
            {:error, :already_consumed}

          Claim.expired?(claim) ->
            {:error, :expired}

          true ->
            instance = claim.instance

            {:ok,
             %{
               claim_id: claim.id,
               instance_id: instance.instance_id,
               public_key: Base.encode64(instance.public_key),
               direct_urls: instance.direct_urls,
               online: instance.online,
               user_id: claim.user_id
             }}
        end
    end
  end

  @doc """
  Marks a claim as consumed.

  Called after successful device pairing.

  ## Parameters
  - `authenticated_instance_id` - The instance_id from the authentication token
  - `claim_id` - The claim ID to consume
  - `device_id` - The device ID that consumed the claim

  Returns `{:ok, claim}` or `{:error, reason}`.
  """
  def consume_claim(authenticated_instance_id, claim_id, device_id) do
    query =
      from c in Claim,
        where: c.id == ^claim_id,
        preload: [:instance]

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      claim ->
        cond do
          claim.instance.instance_id != authenticated_instance_id ->
            {:error, :unauthorized}

          Claim.consumed?(claim) ->
            {:error, :already_consumed}

          true ->
            claim
            |> Claim.consume_changeset(device_id)
            |> Repo.update()
        end
    end
  end

  @doc """
  Deletes expired and consumed claims older than the specified age.
  Used for periodic cleanup.

  ## Parameters
  - `max_age_seconds` - Maximum age in seconds (default: 86400 = 24 hours)

  Returns the number of deleted claims.
  """
  def cleanup_claims(max_age_seconds \\ 86400) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-max_age_seconds, :second)

    query =
      from c in Claim,
        where: c.expires_at < ^cutoff or (not is_nil(c.consumed_at) and c.consumed_at < ^cutoff)

    {count, _} = Repo.delete_all(query)
    count
  end

  @doc """
  Lists all claims for an instance.

  ## Parameters
  - `instance` - The instance
  - `opts` - Options:
    - `:include_expired` - Include expired claims (default: false)
    - `:include_consumed` - Include consumed claims (default: false)
  """
  def list_claims(instance, opts \\ []) do
    include_expired = Keyword.get(opts, :include_expired, false)
    include_consumed = Keyword.get(opts, :include_consumed, false)
    now = DateTime.utc_now()

    query =
      from c in Claim,
        where: c.instance_id == ^instance.id,
        order_by: [desc: c.inserted_at]

    query =
      if include_expired do
        query
      else
        from c in query, where: c.expires_at > ^now
      end

    query =
      if include_consumed do
        query
      else
        from c in query, where: is_nil(c.consumed_at)
      end

    Repo.all(query)
  end

  # ============================================================================
  # Instance Token Generation
  # ============================================================================

  @doc """
  Generates an authentication token for an instance.

  The token is a signed JWT that the instance uses to authenticate
  subsequent requests (heartbeats, claim creation).

  ## Parameters
  - `instance` - The registered instance

  Returns a base64-encoded token string.
  """
  def generate_instance_token(instance) do
    payload = %{
      instance_id: instance.instance_id,
      sub: instance.id,
      iat: System.system_time(:second),
      exp: System.system_time(:second) + 86400 * 7
    }

    # Simple HMAC-based token for now
    # In production, use proper JWT with configurable secret
    secret = get_token_secret()
    data = Jason.encode!(payload)
    signature = :crypto.mac(:hmac, :sha256, secret, data) |> Base.encode64(padding: false)

    Base.encode64("#{data}.#{signature}", padding: false)
  end

  @doc """
  Verifies an instance authentication token.

  Returns `{:ok, instance_id}` or `{:error, reason}`.
  """
  def verify_instance_token(token) do
    with {:ok, decoded} <- Base.decode64(token, padding: false),
         [data, signature] <- String.split(decoded, ".", parts: 2),
         {:ok, expected_sig} <- verify_signature(data, signature),
         true <- expected_sig,
         {:ok, payload} <- Jason.decode(data),
         true <- not token_expired?(payload) do
      {:ok, payload["instance_id"]}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp verify_signature(data, signature) do
    secret = get_token_secret()
    expected = :crypto.mac(:hmac, :sha256, secret, data) |> Base.encode64(padding: false)
    {:ok, Plug.Crypto.secure_compare(expected, signature)}
  end

  defp token_expired?(%{"exp" => exp}) do
    System.system_time(:second) > exp
  end

  defp token_expired?(_), do: true

  defp get_token_secret do
    # Derive relay token secret from the app's secret_key_base
    # No separate secret needed - uses the same one Phoenix uses
    secret_key_base =
      Application.get_env(:metadata_relay, MetadataRelayWeb.Endpoint)[:secret_key_base]

    Plug.Crypto.KeyGenerator.generate(secret_key_base, "relay instance tokens", length: 32)
  end
end
