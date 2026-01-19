defmodule Mydia.RemoteAccess.MediaToken do
  @moduledoc """
  JWT-based authentication for direct media requests.

  Media tokens are used to authenticate remote device access to media resources
  (HLS streams, downloads, thumbnails) without requiring session-based authentication.

  ## Token Payload

      {
        "sub": "device_id",
        "user_id": "user_id",
        "permissions": ["stream", "download", "thumbnails"],
        "iat": timestamp,
        "exp": timestamp + 24_hours
      }

  ## Lifecycle

  1. Issued during device pairing and reconnection
  2. Validated on every direct media request
  3. Refreshed via GraphQL mutation before expiry
  4. Invalidated when device is revoked
  """

  use Guardian, otp_app: :mydia

  import Ecto.Query

  alias Mydia.Repo

  @default_ttl {24, :hours}
  @all_permissions ["stream", "download", "thumbnails"]

  @doc """
  Creates a media token for a remote device.

  ## Options

    * `:ttl` - Token time-to-live (default: 24 hours)
    * `:permissions` - List of permissions (default: all)

  ## Examples

      iex> create_token(%Mydia.RemoteAccess.RemoteDevice{id: "device-123", user_id: "user-456"})
      {:ok, token, claims}

      iex> create_token(device, ttl: {12, :hours}, permissions: ["stream"])
      {:ok, token, claims}
  """
  def create_token(device, opts \\ [])
      when is_struct(device) and is_list(opts) do
    ttl = Keyword.get(opts, :ttl, @default_ttl)
    permissions = Keyword.get(opts, :permissions, @all_permissions)

    claims = %{
      "user_id" => device.user_id,
      "permissions" => permissions,
      "typ" => "media_access"
    }

    encode_and_sign(device, claims, ttl: ttl)
  end

  @doc """
  Verifies a media token and returns the device with user preloaded.

  ## Examples

      iex> verify_token("valid.jwt.token")
      {:ok, %Mydia.RemoteAccess.RemoteDevice{}, claims}

      iex> verify_token("expired.jwt.token")
      {:error, :token_expired}

      iex> verify_token("invalid.jwt.token")
      {:error, :invalid_token}
  """
  def verify_token(token) do
    case decode_and_verify(token, %{"typ" => "media_access"}) do
      {:ok, claims} ->
        case resource_from_claims(claims) do
          {:ok, device} -> {:ok, device, claims}
          error -> error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Refreshes a media token by creating a new one with the same permissions.

  ## Examples

      iex> refresh_token("current.jwt.token")
      {:ok, new_token, claims}
  """
  def refresh_token(token) do
    with {:ok, device, old_claims} <- verify_token(token),
         permissions <- Map.get(old_claims, "permissions", @all_permissions) do
      create_token(device, permissions: permissions)
    end
  end

  @doc """
  Checks if a token has a specific permission.

  ## Examples

      iex> has_permission?(claims, "stream")
      true

      iex> has_permission?(claims, "admin")
      false
  """
  def has_permission?(claims, permission) when is_map(claims) do
    permissions = Map.get(claims, "permissions", [])
    permission in permissions
  end

  # Guardian Callbacks

  @impl Guardian
  def subject_for_token(device, _claims) when is_struct(device) do
    {:ok, to_string(device.id)}
  end

  def subject_for_token(_, _) do
    {:error, :invalid_resource}
  end

  @impl Guardian
  def resource_from_claims(%{"sub" => device_id, "user_id" => user_id} = _claims) do
    # Query device by ID and user_id for security
    # Preload user to have user information available
    query =
      from d in Mydia.RemoteAccess.RemoteDevice,
        where: d.id == ^device_id and d.user_id == ^user_id,
        preload: [:user]

    case Repo.one(query) do
      nil ->
        {:error, :device_not_found}

      device ->
        case device.revoked_at do
          nil -> {:ok, device}
          _ -> {:error, :device_revoked}
        end
    end
  end

  def resource_from_claims(_claims) do
    {:error, :invalid_claims}
  end

  @doc """
  Validates that a device is not revoked.

  This is used by the plug to ensure revoked devices cannot access media.
  """
  def device_active?(device) when is_struct(device) do
    is_nil(device.revoked_at)
  end
end
