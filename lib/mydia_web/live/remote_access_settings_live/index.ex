defmodule MydiaWeb.RemoteAccessSettingsLive.Index do
  use MydiaWeb, :live_view

  alias Mydia.RemoteAccess

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to claim expiry notifications
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Mydia.PubSub, "remote_access:claims")
    end

    {:ok,
     socket
     |> assign(:page_title, "Remote Access Settings")
     |> assign(:claim_code, nil)
     |> assign(:claim_expires_at, nil)
     |> assign(:countdown_seconds, 0)
     |> load_config()}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  ## Event Handlers

  @impl true
  def handle_event("toggle_remote_access", %{"enabled" => enabled_str}, socket) do
    enabled = enabled_str == "true"
    config = socket.assigns.config

    # If enabling and no config exists, initialize keypair
    socket =
      if enabled && is_nil(config) do
        case RemoteAccess.initialize_keypair() do
          {:ok, new_config} ->
            socket
            |> assign(:config, new_config)
            |> put_flash(:info, "Remote access enabled. Keypair initialized.")

          {:error, _changeset} ->
            socket
            |> put_flash(:error, "Failed to initialize remote access")
        end
      else
        socket
      end

    # Toggle enabled state
    case RemoteAccess.toggle_remote_access(enabled) do
      {:ok, updated_config} ->
        {:noreply,
         socket
         |> assign(:config, updated_config)
         |> put_flash(:info, "Remote access #{if enabled, do: "enabled", else: "disabled"}")}

      {:error, :not_configured} ->
        {:noreply,
         socket
         |> put_flash(:error, "Remote access not configured. Please initialize keypair first.")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to update remote access setting")}
    end
  end

  def handle_event("generate_claim_code", _params, socket) do
    user_id = socket.assigns.current_user.id

    case RemoteAccess.generate_claim_code(user_id) do
      {:ok, claim} ->
        # Calculate initial countdown seconds
        expires_at = claim.expires_at
        now = DateTime.utc_now()
        seconds = DateTime.diff(expires_at, now, :second)

        # Schedule the first countdown tick
        Process.send_after(self(), :countdown_tick, 1000)

        {:noreply,
         socket
         |> assign(:claim_code, claim.code)
         |> assign(:claim_expires_at, expires_at)
         |> assign(:countdown_seconds, max(0, seconds))
         |> put_flash(:info, "Pairing code generated")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to generate pairing code")}
    end
  end

  def handle_event("copy_claim_code", _params, socket) do
    # The actual copy happens via JS, this is just for feedback
    {:noreply, put_flash(socket, :info, "Code copied to clipboard")}
  end

  def handle_event("copy_public_key", _params, socket) do
    # The actual copy happens via JS, this is just for feedback
    {:noreply, put_flash(socket, :info, "Public key copied to clipboard")}
  end

  @impl true
  def handle_info(:countdown_tick, socket) do
    claim_expires_at = socket.assigns.claim_expires_at

    if claim_expires_at do
      now = DateTime.utc_now()
      seconds_remaining = DateTime.diff(claim_expires_at, now, :second)

      if seconds_remaining > 0 do
        # Schedule the next tick
        Process.send_after(self(), :countdown_tick, 1000)

        {:noreply, assign(socket, :countdown_seconds, seconds_remaining)}
      else
        # Code expired, clear it
        {:noreply,
         socket
         |> assign(:claim_code, nil)
         |> assign(:claim_expires_at, nil)
         |> assign(:countdown_seconds, 0)
         |> put_flash(:info, "Pairing code expired")}
      end
    else
      {:noreply, socket}
    end
  end

  ## Private Helpers

  defp load_config(socket) do
    config = RemoteAccess.get_config()
    assign(socket, :config, config)
  end

  defp format_countdown(seconds) when seconds <= 0, do: "Expired"

  defp format_countdown(seconds) do
    minutes = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{minutes}:#{String.pad_leading(Integer.to_string(secs), 2, "0")}"
  end

  defp generate_qr_code(config) do
    if config && config.static_public_key do
      # Build QR code content
      content =
        Jason.encode!(%{
          instance_id: config.instance_id,
          public_key: Base.encode64(config.static_public_key),
          relay_url: config.relay_url || "wss://relay.mydia.app"
        })

      # Generate QR code as SVG
      # EQRCode.encode returns the matrix directly, not a tuple
      qr_code = EQRCode.encode(content)
      EQRCode.svg(qr_code, width: 200)
    else
      nil
    end
  end
end
