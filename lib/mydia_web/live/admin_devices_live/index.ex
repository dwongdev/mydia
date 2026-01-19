defmodule MydiaWeb.AdminDevicesLive.Index do
  use MydiaWeb, :live_view

  alias Mydia.RemoteAccess
  alias Mydia.RemoteAccess.RemoteDevice

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Device Management")
     |> assign(:show_revoke_modal, false)
     |> assign(:selected_device, nil)
     |> load_devices()}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  ## Event Handlers

  @impl true
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

  ## Private Helpers

  defp load_devices(socket) do
    # Get all devices for current user
    user_id = socket.assigns.current_user.id
    devices = RemoteAccess.list_devices(user_id)

    assign(socket, :devices, devices)
  end

  defp format_datetime(nil), do: "Never"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %Y at %I:%M %p")
  end

  defp status_badge_class(%RemoteDevice{revoked_at: nil, last_seen_at: last_seen}) do
    if is_recent_activity?(last_seen) do
      "badge-success"
    else
      "badge-warning"
    end
  end

  defp status_badge_class(%RemoteDevice{revoked_at: _revoked}), do: "badge-error"

  defp status_text(%RemoteDevice{revoked_at: nil, last_seen_at: last_seen}) do
    if is_recent_activity?(last_seen) do
      "Active"
    else
      "Inactive"
    end
  end

  defp status_text(%RemoteDevice{revoked_at: _revoked}), do: "Revoked"

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
end
