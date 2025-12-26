defmodule MydiaWeb.Schema.Resolvers.RemoteAccessResolver do
  @moduledoc """
  Resolvers for remote access GraphQL mutations (media token management).
  """

  alias Mydia.RemoteAccess.MediaToken

  def refresh_media_token(_parent, %{token: token}, _context) do
    case MediaToken.refresh_token(token) do
      {:ok, new_token, claims} ->
        expires_at = DateTime.from_unix!(claims["exp"])
        permissions = Map.get(claims, "permissions", [])

        {:ok,
         %{
           token: new_token,
           expires_at: expires_at,
           permissions: permissions
         }}

      {:error, :token_expired} ->
        {:error, "Token has expired"}

      {:error, :invalid_token} ->
        {:error, "Invalid token"}

      {:error, :device_not_found} ->
        {:error, "Device not found"}

      {:error, :device_revoked} ->
        {:error, "Device has been revoked"}

      {:error, reason} ->
        {:error, "Failed to refresh token: #{inspect(reason)}"}
    end
  end
end
