defmodule MydiaWeb.Plugs.RelayDeviceAuthTest do
  use MydiaWeb.ConnCase, async: true

  alias MydiaWeb.Plugs.RelayDeviceAuth
  alias Mydia.RemoteAccess
  alias Mydia.Accounts

  describe "call/2" do
    test "sets current_user and relay_device for valid relay request", %{conn: conn} do
      user = create_user()
      device = create_device(user.id)

      conn =
        conn
        |> put_relay_headers(device.id)
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> RelayDeviceAuth.call([])

      assert conn.assigns.current_user.id == user.id
      assert conn.assigns.relay_device.id == device.id
      assert conn.assigns.current_scope.id == user.id
    end

    test "sets current_user via Guardian for downstream compatibility", %{conn: conn} do
      user = create_user()
      device = create_device(user.id)

      conn =
        conn
        |> put_relay_headers(device.id)
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> RelayDeviceAuth.call([])

      # Guardian should also have the current resource set
      assert Mydia.Auth.Guardian.Plug.current_resource(conn).id == user.id
    end

    test "passes through without setting user for revoked device", %{conn: conn} do
      user = create_user()
      device = create_device(user.id)

      # Revoke the device
      {:ok, _revoked_device} = RemoteAccess.revoke_device(device)

      conn =
        conn
        |> put_relay_headers(device.id)
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> RelayDeviceAuth.call([])

      refute Map.has_key?(conn.assigns, :current_user)
      refute Map.has_key?(conn.assigns, :relay_device)
    end

    test "passes through without setting user for non-existent device", %{conn: conn} do
      fake_device_id = Ecto.UUID.generate()

      conn =
        conn
        |> put_relay_headers(fake_device_id)
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> RelayDeviceAuth.call([])

      refute Map.has_key?(conn.assigns, :current_user)
      refute Map.has_key?(conn.assigns, :relay_device)
    end

    test "passes through unchanged for non-relay request", %{conn: conn} do
      user = create_user()
      device = create_device(user.id)

      conn =
        conn
        |> put_req_header("x-relay-device-id", device.id)
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> RelayDeviceAuth.call([])

      refute Map.has_key?(conn.assigns, :current_user)
      refute Map.has_key?(conn.assigns, :relay_device)
    end

    test "passes through unchanged for relay headers from non-localhost (security)", %{conn: conn} do
      user = create_user()
      device = create_device(user.id)

      conn =
        conn
        |> put_relay_headers(device.id)
        |> Map.put(:remote_ip, {192, 168, 1, 100})
        |> RelayDeviceAuth.call([])

      refute Map.has_key?(conn.assigns, :current_user)
      refute Map.has_key?(conn.assigns, :relay_device)
    end

    test "passes through unchanged when missing x-relay-device-id header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-relay-tunnel", "true")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> RelayDeviceAuth.call([])

      refute Map.has_key?(conn.assigns, :current_user)
      refute Map.has_key?(conn.assigns, :relay_device)
    end

    test "accepts IPv6 localhost", %{conn: conn} do
      user = create_user()
      device = create_device(user.id)

      conn =
        conn
        |> put_relay_headers(device.id)
        |> Map.put(:remote_ip, {0, 0, 0, 0, 0, 0, 0, 1})
        |> RelayDeviceAuth.call([])

      assert conn.assigns.current_user.id == user.id
      assert conn.assigns.relay_device.id == device.id
    end

    test "x-relay-tunnel header must be exactly 'true'", %{conn: conn} do
      user = create_user()
      device = create_device(user.id)
      timestamp = System.system_time(:second) |> Integer.to_string()
      signature = compute_signature(device.id, timestamp)

      conn =
        conn
        |> put_req_header("x-relay-tunnel", "yes")
        |> put_req_header("x-relay-device-id", device.id)
        |> put_req_header("x-relay-timestamp", timestamp)
        |> put_req_header("x-relay-signature", signature)
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> RelayDeviceAuth.call([])

      refute Map.has_key?(conn.assigns, :current_user)
      refute Map.has_key?(conn.assigns, :relay_device)
    end

    test "rejects request with invalid signature", %{conn: conn} do
      user = create_user()
      device = create_device(user.id)
      timestamp = System.system_time(:second) |> Integer.to_string()

      conn =
        conn
        |> put_req_header("x-relay-tunnel", "true")
        |> put_req_header("x-relay-device-id", device.id)
        |> put_req_header("x-relay-timestamp", timestamp)
        |> put_req_header("x-relay-signature", "invalid-signature")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> RelayDeviceAuth.call([])

      refute Map.has_key?(conn.assigns, :current_user)
      refute Map.has_key?(conn.assigns, :relay_device)
    end

    test "rejects request with expired timestamp", %{conn: conn} do
      user = create_user()
      device = create_device(user.id)
      # Timestamp from 2 minutes ago (beyond 60 second window)
      old_timestamp = (System.system_time(:second) - 120) |> Integer.to_string()
      signature = compute_signature(device.id, old_timestamp)

      conn =
        conn
        |> put_req_header("x-relay-tunnel", "true")
        |> put_req_header("x-relay-device-id", device.id)
        |> put_req_header("x-relay-timestamp", old_timestamp)
        |> put_req_header("x-relay-signature", signature)
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> RelayDeviceAuth.call([])

      refute Map.has_key?(conn.assigns, :current_user)
      refute Map.has_key?(conn.assigns, :relay_device)
    end

    test "rejects request with missing signature headers", %{conn: conn} do
      user = create_user()
      device = create_device(user.id)

      conn =
        conn
        |> put_req_header("x-relay-tunnel", "true")
        |> put_req_header("x-relay-device-id", device.id)
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> RelayDeviceAuth.call([])

      refute Map.has_key?(conn.assigns, :current_user)
      refute Map.has_key?(conn.assigns, :relay_device)
    end
  end

  # Helper functions

  defp create_user do
    num = System.unique_integer([:positive])
    username = "user#{num}"
    email = "#{username}@example.com"

    {:ok, user} =
      Accounts.create_user(%{
        username: username,
        email: email,
        password: "password123456",
        role: "admin"
      })

    user
  end

  defp create_device(user_id) do
    token = :crypto.strong_rand_bytes(32) |> Base.encode64()

    {:ok, device} =
      RemoteAccess.create_device(%{
        device_name: "Test Device",
        platform: "ios",
        device_static_public_key: :crypto.strong_rand_bytes(32),
        token: token,
        user_id: user_id
      })

    device
  end

  # Adds all required relay headers including HMAC signature
  defp put_relay_headers(conn, device_id) do
    timestamp = System.system_time(:second) |> Integer.to_string()
    signature = compute_signature(device_id, timestamp)

    conn
    |> put_req_header("x-relay-tunnel", "true")
    |> put_req_header("x-relay-device-id", device_id)
    |> put_req_header("x-relay-timestamp", timestamp)
    |> put_req_header("x-relay-signature", signature)
  end

  # Computes HMAC-SHA256 signature matching the relay tunnel implementation
  defp compute_signature(device_id, timestamp) do
    secret = Application.get_env(:mydia, :relay_tunnel_secret)
    message = "#{device_id}:#{timestamp}"
    :crypto.mac(:hmac, :sha256, secret, message) |> Base.encode64()
  end
end
