defmodule MetadataRelay.Relay.Handler do
  @moduledoc """
  HTTP handler for relay API endpoints.

  Implements the relay REST API:
  - POST /relay/instances - Register new instance
  - PUT /relay/instances/:id/heartbeat - Update presence/URLs
  - POST /relay/instances/:id/claim - Create claim code
  - POST /relay/claim/:code - Redeem claim code
  - GET /relay/instances/:id/connect - Get connection info
  """

  alias MetadataRelay.Relay

  @doc """
  Registers a new instance with the relay.

  ## Request Body
  ```json
  {
    "instance_id": "uuid-string",
    "public_key": "base64-encoded-32-byte-key",
    "direct_urls": ["https://mydia.local:4000"]
  }
  ```

  ## Response
  ```json
  {
    "instance_id": "uuid-string",
    "token": "auth-token-for-future-requests"
  }
  ```
  """
  def register_instance(params) do
    with {:ok, public_key} <- decode_public_key(params["public_key"]),
         attrs <- %{
           instance_id: params["instance_id"],
           public_key: public_key,
           direct_urls: params["direct_urls"] || []
         },
         {:ok, instance} <- Relay.register_instance(attrs) do
      token = Relay.generate_instance_token(instance)

      {:ok,
       %{
         instance_id: instance.instance_id,
         token: token
       }}
    else
      {:error, :invalid_public_key} ->
        {:error, {:validation, "public_key must be a valid base64-encoded 32-byte key"}}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, {:validation, format_changeset_errors(changeset)}}
    end
  end

  @doc """
  Updates instance heartbeat/presence.

  ## Request Body
  ```json
  {
    "direct_urls": ["https://mydia.local:4000"]
  }
  ```

  ## Response
  ```json
  {
    "status": "ok",
    "last_seen_at": "2025-01-01T00:00:00Z"
  }
  ```
  """
  def update_heartbeat(instance_id, params) do
    case Relay.get_instance(instance_id) do
      nil ->
        {:error, :not_found}

      instance ->
        attrs = %{direct_urls: params["direct_urls"] || instance.direct_urls}

        case Relay.update_heartbeat(instance, attrs) do
          {:ok, updated} ->
            {:ok,
             %{
               status: "ok",
               last_seen_at: updated.last_seen_at
             }}

          {:error, changeset} ->
            {:error, {:validation, format_changeset_errors(changeset)}}
        end
    end
  end

  @doc """
  Creates a new claim code for device pairing.

  ## Request Body
  ```json
  {
    "user_id": "user-uuid",
    "ttl_seconds": 300
  }
  ```

  ## Response
  ```json
  {
    "code": "ABC123",
    "expires_at": "2025-01-01T00:05:00Z"
  }
  ```
  """
  def create_claim(instance_id, params) do
    case Relay.get_instance(instance_id) do
      nil ->
        {:error, :not_found}

      instance ->
        user_id = params["user_id"]
        ttl = params["ttl_seconds"] || 300

        case Relay.create_claim(instance, user_id, ttl_seconds: ttl) do
          {:ok, claim} ->
            {:ok,
             %{
               code: claim.code,
               expires_at: claim.expires_at
             }}

          {:error, changeset} ->
            {:error, {:validation, format_changeset_errors(changeset)}}
        end
    end
  end

  @doc """
  Redeems a claim code.

  Returns instance connection info if the code is valid.

  ## Response
  ```json
  {
    "claim_id": "uuid",
    "instance_id": "instance-uuid",
    "public_key": "base64-encoded-key",
    "direct_urls": ["https://mydia.local:4000"],
    "online": true,
    "user_id": "user-uuid"
  }
  ```
  """
  def redeem_claim(code) do
    case Relay.redeem_claim(code) do
      {:ok, info} ->
        {:ok, info}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :already_consumed} ->
        {:error, {:validation, "Claim code has already been used"}}

      {:error, :expired} ->
        {:error, {:validation, "Claim code has expired"}}
    end
  end

  @doc """
  Marks a claim as consumed after successful pairing.

  ## Request Body
  ```json
  {
    "claim_id": "claim-uuid",
    "device_id": "device-uuid"
  }
  ```
  """
  def consume_claim(authenticated_instance_id, params) do
    claim_id = params["claim_id"]
    device_id = params["device_id"]

    case Relay.consume_claim(authenticated_instance_id, claim_id, device_id) do
      {:ok, _claim} ->
        {:ok, %{status: "consumed"}}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :already_consumed} ->
        {:error, {:validation, "Claim code has already been consumed"}}

      {:error, :unauthorized} ->
        {:error, {:validation, "Only the instance that created the claim can consume it"}}
    end
  end

  @doc """
  Gets connection info for an instance.

  Used by clients to get the info needed to connect.

  ## Response
  ```json
  {
    "instance_id": "instance-uuid",
    "public_key": "base64-encoded-key",
    "direct_urls": ["https://mydia.local:4000"],
    "online": true,
    "last_seen_at": "2025-01-01T00:00:00Z"
  }
  ```
  """
  def get_connection_info(instance_id) do
    Relay.get_connection_info(instance_id)
  end

  # Private helpers

  defp decode_public_key(nil), do: {:error, :invalid_public_key}

  defp decode_public_key(base64_key) when is_binary(base64_key) do
    case Base.decode64(base64_key) do
      {:ok, key} when byte_size(key) == 32 -> {:ok, key}
      _ -> {:error, :invalid_public_key}
    end
  end

  defp decode_public_key(_), do: {:error, :invalid_public_key}

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map(fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
    |> Enum.join("; ")
  end
end
