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

  require Logger

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
      on_conflict: {:replace, [:public_key, :direct_urls, :public_ip, :updated_at]},
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
    code = normalize_claim_code(code)

    query =
      from(c in Claim,
        where: c.code == ^code,
        preload: [:instance]
      )

    result =
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

              # Enrich direct_urls with public IP (Plex-like auto-discovery)
              enriched_urls = build_enriched_urls(instance)

              {:ok,
               %{
                 claim_id: claim.id,
                 instance_id: instance.instance_id,
                 public_key: Base.encode64(instance.public_key),
                 direct_urls: enriched_urls,
                 online: instance.online,
                 user_id: claim.user_id
               }}
          end
      end

    # Security audit logging - log only code prefix to avoid exposing full codes
    log_claim_attempt(code, result)

    result
  end

  @doc """
  Resolves a claim code to a rendezvous namespace and connection info.

  Used by the player to find the server via P2P rendezvous.
  """
  def resolve_claim(code) do
    code = normalize_claim_code(code)

    query =
      from(c in Claim,
        where: c.code == ^code
      )

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      claim ->
        cond do
          Claim.consumed?(claim) ->
            {:error, :already_consumed}

          Claim.expired?(claim) ->
            {:error, :expired}

          Claim.locked?(claim) ->
            # If locked but not consumed, it's in progress.
            # We treat it as valid for resolve so the player can retry if needed?
            # Or should we block it? The plan says "Lock transitions VALID -> IN_PROGRESS".
            # Plan says: "If resolve endpoint returns invalid/expired/consumed -> display 'Invalid or expired code'"
            # It doesn't explicitly say what to do if locked.
            # However, "Lock mechanism (prevents race conditions): When server receives pairing request, calls POST /relay/claim/:code/lock"
            # So resolve happens BEFORE lock.
            # If someone else is pairing (locked), resolve should probably still work?
            # Actually, if it's locked, it means a pairing attempt is in progress.
            # If I try to resolve it, maybe I should be allowed to? 
            # But the lock is to prevent multiple servers claiming the code? No, the server locks it.
            # Wait, the SERVER calls lock. The PLAYER calls resolve.
            # 1. Player enters code.
            # 2. Player calls resolve -> gets namespace.
            # 3. Player discovers Server.
            # 4. Player connects to Server.
            # 5. Server calls lock.
            # So resolving a locked claim is fine, because the lock is for the final step.
            # Actually, if it's locked, it means the server is processing a pairing request.
            # If another player tries to resolve, they might interfere?
            # But resolve just gives the namespace. It doesn't change state.
            process_resolve(claim, code)

          true ->
            process_resolve(claim, code)
        end
    end
  end

  defp process_resolve(claim, code) do
    # The iroh relay URL for P2P connections
    # Clients use this for direct P2P rendezvous via the standalone iroh-relay service
    relay_url = "https://p2p.mydia.dev"

    namespace = MetadataRelay.Relay.Namespace.derive_namespace(code)

    {:ok,
     %{
       namespace: namespace,
       expires_at: claim.expires_at,
       relay_url: relay_url
     }}
  end

  @doc """
  Locks a claim code to prevent race conditions during pairing.

  Transitions VALID -> IN_PROGRESS.
  Returns 409 if already locked.
  """
  def lock_claim(code) do
    code = normalize_claim_code(code)

    query = from(c in Claim, where: c.code == ^code)

    Repo.transaction(fn ->
      case Repo.one(query, lock: "FOR UPDATE") do
        nil ->
          Repo.rollback(:not_found)

        claim ->
          cond do
            Claim.consumed?(claim) ->
              Repo.rollback(:already_consumed)

            Claim.expired?(claim) ->
              Repo.rollback(:expired)

            Claim.locked?(claim) ->
              Repo.rollback(:locked)

            true ->
              case Repo.update(Claim.lock_changeset(claim)) do
                {:ok, updated} -> updated
                {:error, changeset} -> Repo.rollback(changeset)
              end
          end
      end
    end)
  end

  # Log claim redemption attempts for security monitoring
  # Only logs code prefix (first 2 chars) to avoid exposing sensitive codes
  defp log_claim_attempt(code, {:ok, %{instance_id: instance_id}}) do
    Logger.info("Claim redeemed successfully",
      code_prefix: String.slice(code, 0, 2),
      instance_id: instance_id
    )
  end

  defp log_claim_attempt(code, {:error, reason}) do
    Logger.warning("Claim redemption failed",
      code_prefix: String.slice(code, 0, 2),
      reason: reason
    )
  end

  # Builds enriched URL list by adding public IP URL to stored direct_urls
  defp build_enriched_urls(instance) do
    # Start with stored local URLs
    local_urls = instance.direct_urls || []

    # Extract port from existing URLs, default to 4000
    port = extract_port_from_urls(local_urls)

    # Build public URL if we have a detected public IP
    public_url =
      if instance.public_ip && is_valid_public_ip?(instance.public_ip) do
        build_sslip_url(instance.public_ip, port)
      end

    # Combine: local URLs first (faster on LAN), public URL last
    (local_urls ++ [public_url])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Extracts port number from the first URL that has one
  defp extract_port_from_urls([url | rest]) when is_binary(url) do
    case URI.parse(url) do
      %URI{port: port} when is_integer(port) -> port
      _ -> extract_port_from_urls(rest)
    end
  end

  defp extract_port_from_urls([_ | rest]), do: extract_port_from_urls(rest)
  defp extract_port_from_urls([]), do: 4000

  # Validates that an IP is a public IP (not loopback, private, or link-local)
  defp is_valid_public_ip?(ip) when is_binary(ip) do
    case String.split(ip, ".") do
      [a, b, _, _] ->
        {a_int, _} = Integer.parse(a)
        {b_int, _} = Integer.parse(b)

        # Loopback
        # Private 10.x.x.x
        # Private 172.16-31.x.x
        # Private 192.168.x.x
        # Link-local
        not (a_int == 127 ||
               a_int == 10 ||
               (a_int == 172 && b_int >= 16 && b_int <= 31) ||
               (a_int == 192 && b_int == 168) ||
               (a_int == 169 && b_int == 254))

      _ ->
        false
    end
  end

  defp is_valid_public_ip?(_), do: false

  # Builds an sslip.io URL from an IP string
  defp build_sslip_url(ip, port) when is_binary(ip) and is_integer(port) do
    # Convert "203.0.113.50" to "203-0-113-50"
    ip_dashed = String.replace(ip, ".", "-")
    "https://#{ip_dashed}.sslip.io:#{port}"
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
      from(c in Claim,
        where: c.id == ^claim_id,
        preload: [:instance]
      )

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
      from(c in Claim,
        where: c.expires_at < ^cutoff or (not is_nil(c.consumed_at) and c.consumed_at < ^cutoff)
      )

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
      from(c in Claim,
        where: c.instance_id == ^instance.id,
        order_by: [desc: c.inserted_at]
      )

    query =
      if include_expired do
        query
      else
        from(c in query, where: c.expires_at > ^now)
      end

    query =
      if include_consumed do
        query
      else
        from(c in query, where: is_nil(c.consumed_at))
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

  # Normalizes a claim code by removing whitespace/dashes and uppercasing.
  # Codes are stored without dashes, so normalization only cleans user input.
  defp normalize_claim_code(code) when is_binary(code) do
    code
    |> String.upcase()
    |> String.replace(~r/[-\s]/, "")
  end

  defp normalize_claim_code(code), do: code
end
