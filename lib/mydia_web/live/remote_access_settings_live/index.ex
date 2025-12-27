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
     |> assign(:show_revoke_modal, false)
     |> assign(:selected_device, nil)
     |> assign(:show_delete_modal, false)
     |> assign(:device_to_delete, nil)
     |> assign(:show_add_url_modal, false)
     |> assign(:new_url, "")
     # Read relay URL from environment, not database
     |> assign(:relay_url, Mydia.Metadata.metadata_relay_url())
     |> load_config()
     |> load_devices()
     |> load_relay_status()}
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

    # If enabling and no config exists, initialize keypair first
    with {:ok, socket} <- maybe_initialize_keypair(socket, config, enabled),
         {:ok, updated_config} <- RemoteAccess.toggle_remote_access(enabled) do
      {:noreply,
       socket
       |> assign(:config, updated_config)
       |> load_relay_status()
       |> put_flash(:info, "Remote access #{if enabled, do: "enabled", else: "disabled"}")}
    else
      {:error, :init_failed, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to initialize remote access: #{format_errors(changeset)}")}

      {:error, :not_configured} ->
        {:noreply,
         socket
         |> put_flash(:error, "Remote access not configured. Please try again.")}

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

      {:error, :relay_not_connected} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to generate pairing code: relay service not connected")}

      {:error, :relay_timeout} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to generate pairing code: relay service timeout")}

      {:error, {:relay_error, _reason}} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to generate pairing code: relay service error")}

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

  def handle_event("copy_instance_id", _params, socket) do
    # The actual copy happens via JS, this is just for feedback
    {:noreply, put_flash(socket, :info, "Instance ID copied to clipboard")}
  end

  def handle_event("open_revoke_modal", %{"id" => id}, socket) do
    device = RemoteAccess.get_device!(id)

    {:noreply,
     socket
     |> assign(:show_revoke_modal, true)
     |> assign(:selected_device, device)}
  end

  def handle_event("close_revoke_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_revoke_modal, false)
     |> assign(:selected_device, nil)}
  end

  def handle_event("submit_revoke", _params, socket) do
    device = socket.assigns.selected_device

    case RemoteAccess.revoke_device(device) do
      {:ok, _revoked_device} ->
        {:noreply,
         socket
         |> assign(:show_revoke_modal, false)
         |> assign(:selected_device, nil)
         |> put_flash(:info, "Device revoked successfully.")
         |> load_devices()}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to revoke device")}
    end
  end

  def handle_event("open_delete_modal", %{"id" => id}, socket) do
    device = RemoteAccess.get_device!(id)

    {:noreply,
     socket
     |> assign(:show_delete_modal, true)
     |> assign(:device_to_delete, device)}
  end

  def handle_event("close_delete_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_delete_modal, false)
     |> assign(:device_to_delete, nil)}
  end

  def handle_event("submit_delete", _params, socket) do
    device = socket.assigns.device_to_delete

    case RemoteAccess.delete_device(device) do
      {:ok, _deleted_device} ->
        {:noreply,
         socket
         |> assign(:show_delete_modal, false)
         |> assign(:device_to_delete, nil)
         |> put_flash(:info, "Device deleted successfully.")
         |> load_devices()}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete device")}
    end
  end

  def handle_event("open_add_url_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_url_modal, true)
     |> assign(:new_url, "")}
  end

  def handle_event("close_add_url_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_url_modal, false)
     |> assign(:new_url, "")}
  end

  def handle_event("update_new_url", %{"value" => value}, socket) do
    {:noreply, assign(socket, :new_url, value)}
  end

  def handle_event("add_direct_url", _params, socket) do
    config = socket.assigns.config
    new_url = String.trim(socket.assigns.new_url)

    if new_url != "" do
      current_urls = config.direct_urls || []
      updated_urls = Enum.uniq(current_urls ++ [new_url])

      case RemoteAccess.update_relay_urls(updated_urls) do
        {:ok, _urls} ->
          {:noreply,
           socket
           |> assign(:show_add_url_modal, false)
           |> assign(:new_url, "")
           |> load_config()
           |> put_flash(:info, "Direct URL added successfully")}

        {:error, _reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to add direct URL")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_direct_url", %{"url" => url}, socket) do
    config = socket.assigns.config
    current_urls = config.direct_urls || []
    updated_urls = Enum.reject(current_urls, &(&1 == url))

    case RemoteAccess.update_relay_urls(updated_urls) do
      {:ok, _urls} ->
        {:noreply,
         socket
         |> load_config()
         |> put_flash(:info, "Direct URL removed successfully")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to remove direct URL")}
    end
  end

  def handle_event("reconnect_relay", _params, socket) do
    case RemoteAccess.reconnect_relay() do
      :ok ->
        # Give the relay a moment to reconnect
        Process.send_after(self(), :refresh_relay_status, 1000)

        {:noreply,
         socket
         |> put_flash(:info, "Relay reconnection initiated")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to reconnect relay")}
    end
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

  def handle_info(:refresh_relay_status, socket) do
    {:noreply, load_relay_status(socket)}
  end

  ## Private Helpers

  defp maybe_initialize_keypair(socket, nil, true) do
    case RemoteAccess.initialize_keypair() do
      {:ok, new_config} ->
        {:ok, assign(socket, :config, new_config)}

      {:error, changeset} ->
        {:error, :init_failed, changeset}
    end
  end

  defp maybe_initialize_keypair(socket, _config, _enabled), do: {:ok, socket}

  defp format_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map(fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
    |> Enum.join("; ")
  end

  defp format_errors(_), do: "unknown error"

  defp load_config(socket) do
    config = RemoteAccess.get_config()
    assign(socket, :config, config)
  end

  defp load_devices(socket) do
    user_id = socket.assigns.current_user.id
    devices = RemoteAccess.list_devices(user_id)
    assign(socket, :devices, devices)
  end

  defp load_relay_status(socket) do
    relay_status =
      case RemoteAccess.relay_status() do
        {:ok, status} -> status
        {:error, _} -> nil
      end

    assign(socket, :relay_status, relay_status)
  end

  defp format_countdown(seconds) when seconds <= 0, do: "Expired"

  defp format_countdown(seconds) do
    minutes = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{minutes}:#{String.pad_leading(Integer.to_string(secs), 2, "0")}"
  end

  defp format_datetime(nil), do: "Never"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %Y at %I:%M %p")
  end

  defp status_badge_class(%RemoteAccess.RemoteDevice{revoked_at: nil, last_seen_at: last_seen}) do
    if is_recent_activity?(last_seen) do
      "badge-success"
    else
      "badge-warning"
    end
  end

  defp status_badge_class(%RemoteAccess.RemoteDevice{revoked_at: _revoked}), do: "badge-error"

  defp status_text(%RemoteAccess.RemoteDevice{revoked_at: nil, last_seen_at: last_seen}) do
    if is_recent_activity?(last_seen) do
      "Active"
    else
      "Inactive"
    end
  end

  defp status_text(%RemoteAccess.RemoteDevice{revoked_at: _revoked}), do: "Revoked"

  # Consider a device active if it was seen in the last 7 days
  defp is_recent_activity?(nil), do: false

  defp is_recent_activity?(last_seen) do
    seven_days_ago = DateTime.utc_now() |> DateTime.add(-7, :day)
    DateTime.compare(last_seen, seven_days_ago) == :gt
  end

  defp platform_icon("ios"), do: "hero-device-phone-mobile"
  defp platform_icon("android"), do: "hero-device-phone-mobile"
  defp platform_icon("web"), do: "hero-computer-desktop"
  defp platform_icon(_), do: "hero-device-tablet"

  defp generate_qr_code(config, relay_url) do
    if config && config.static_public_key do
      # Build QR code content
      content =
        Jason.encode!(%{
          instance_id: config.instance_id,
          public_key: Base.encode64(config.static_public_key),
          relay_url: relay_url
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
