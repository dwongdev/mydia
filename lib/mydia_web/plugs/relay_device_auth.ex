defmodule MydiaWeb.Plugs.RelayDeviceAuth do
  @moduledoc """
  Authenticates relay-tunneled requests using the x-relay-device-id header.

  The relay tunnel authenticates devices during handshake and injects this header.

  ## Security Model (Defense in Depth)

  - Only activates for requests with `x-relay-tunnel: true` header
  - Only trusts requests from localhost (127.0.0.1 or ::1)
  - Verifies HMAC-SHA256 signature to prevent header injection attacks
  - Validates timestamp to prevent replay attacks (60 second window)
  - Loads the device and preloads the user association
  - Non-relay requests pass through unchanged
  """

  import Plug.Conn
  require Logger

  alias Mydia.RemoteAccess
  alias Mydia.Auth.Guardian

  # Maximum age for relay timestamps (60 seconds)
  @max_timestamp_age 60

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["true"] <- get_req_header(conn, "x-relay-tunnel"),
         [device_id] <- get_req_header(conn, "x-relay-device-id"),
         true <- from_localhost?(conn),
         :ok <- verify_signature(conn, device_id),
         {:ok, device} <- RemoteAccess.get_active_device(device_id) do
      # Update last_seen_at asynchronously (throttled to avoid DB writes on every request)
      RemoteAccess.touch_device_async(device)

      conn
      |> assign(:relay_device, device)
      |> assign(:current_user, device.user)
      |> assign(:current_scope, device.user)
      |> Guardian.Plug.put_current_resource(device.user)
    else
      # Not a relay request or invalid - continue normally
      _ -> conn
    end
  end

  defp from_localhost?(conn) do
    conn.remote_ip in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]
  end

  # Verifies the HMAC signature and timestamp for relay tunnel requests.
  # Returns :ok if valid, {:error, reason} otherwise.
  defp verify_signature(conn, device_id) do
    with [timestamp_str] <- get_req_header(conn, "x-relay-timestamp"),
         [signature] <- get_req_header(conn, "x-relay-signature"),
         {timestamp, ""} <- Integer.parse(timestamp_str),
         true <- timestamp_valid?(timestamp),
         true <- signature_valid?(device_id, timestamp_str, signature) do
      :ok
    else
      [] ->
        Logger.debug("Relay auth: missing signature headers")
        {:error, :missing_signature}

      false ->
        Logger.warning("Relay auth: invalid signature or expired timestamp")
        {:error, :invalid_signature}

      _ ->
        Logger.debug("Relay auth: signature verification failed")
        {:error, :verification_failed}
    end
  end

  # Checks if the timestamp is within the allowed window
  defp timestamp_valid?(timestamp) do
    now = System.system_time(:second)
    abs(now - timestamp) <= @max_timestamp_age
  end

  # Verifies the HMAC-SHA256 signature using constant-time comparison
  defp signature_valid?(device_id, timestamp, provided_signature) do
    secret = Application.get_env(:mydia, :relay_tunnel_secret)
    message = "#{device_id}:#{timestamp}"
    expected = :crypto.mac(:hmac, :sha256, secret, message) |> Base.encode64()
    Plug.Crypto.secure_compare(expected, provided_signature)
  end
end
