defmodule MydiaWeb.AdminConfigLive.RemoteAccessComponent do
  @moduledoc """
  LiveComponent for managing remote access settings.

  This component provides an inline interface for configuring remote access,
  managing paired devices, and generating pairing codes.
  """
  use MydiaWeb, :live_component

  alias Mydia.RemoteAccess

  @impl true
  def update(%{countdown_tick: true} = _assigns, socket) do
    # Handle countdown tick from parent
    socket = handle_countdown_tick(socket)
    {:ok, socket}
  end

  def update(%{refresh_relay: true} = _assigns, socket) do
    # Handle relay status refresh from parent
    {:ok, load_relay_status(socket)}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:claim_code, fn -> nil end)
      |> assign_new(:claim_expires_at, fn -> nil end)
      |> assign_new(:countdown_seconds, fn -> 0 end)
      |> assign_new(:show_revoke_modal, fn -> false end)
      |> assign_new(:selected_device, fn -> nil end)
      |> assign_new(:show_delete_modal, fn -> false end)
      |> assign_new(:device_to_delete, fn -> nil end)
      |> assign_new(:show_add_url_modal, fn -> false end)
      |> assign_new(:new_url, fn -> "" end)
      |> assign_new(:show_advanced, fn -> false end)
      # Read relay URL from environment, not database
      |> assign(:relay_url, Mydia.Metadata.metadata_relay_url())
      |> load_config()
      |> load_devices()
      |> load_relay_status()

    # Subscribe to claim expiry notifications on first mount
    if connected?(socket) and is_nil(assigns[:subscribed]) do
      Phoenix.PubSub.subscribe(Mydia.PubSub, "remote_access:claims")
    end

    {:ok, assign(socket, :subscribed, true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <%!-- Main Toggle with Status --%>
      <div class="card bg-base-200">
        <div class="card-body">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-4">
              <div class={[
                "w-12 h-12 rounded-full flex items-center justify-center",
                if(@ra_config && @ra_config.enabled && @relay_status && @relay_status.connected,
                  do: "bg-success/20",
                  else: "bg-base-300"
                )
              ]}>
                <.icon
                  name={
                    if @ra_config && @ra_config.enabled && @relay_status && @relay_status.connected,
                      do: "hero-signal",
                      else: "hero-signal-slash"
                  }
                  class={
                    if @ra_config && @ra_config.enabled && @relay_status && @relay_status.connected,
                      do: "w-6 h-6 text-success",
                      else: "w-6 h-6 text-base-content/40"
                  }
                />
              </div>
              <div>
                <h3 class="font-semibold text-lg">Remote Access</h3>
                <p class="text-sm text-base-content/70">
                  <%= cond do %>
                    <% !@ra_config || !@ra_config.enabled -> %>
                      Disabled - mobile apps cannot connect
                    <% @relay_status && @relay_status.connected -> %>
                      <span class="text-success">Connected and ready for devices</span>
                    <% true -> %>
                      <span class="text-warning">Enabled but not connected</span>
                  <% end %>
                </p>
              </div>
            </div>
            <div class="flex items-center gap-2">
              <input
                type="checkbox"
                id="remote-access-toggle"
                class="toggle toggle-primary toggle-lg"
                checked={@ra_config && @ra_config.enabled}
                name="remote_access_enabled"
                phx-click="toggle_remote_access"
                phx-target={@myself}
                phx-value-enabled={to_string(!(@ra_config && @ra_config.enabled))}
              />
              <%!-- Test button without phx-target to verify events work --%>
              <button
                type="button"
                class="btn btn-xs btn-primary"
                phx-click="test_parent_event"
              >
                (test parent)
              </button>
            </div>
          </div>

          <%!-- Reconnect hint when enabled but disconnected --%>
          <%= if @ra_config && @ra_config.enabled && (!@relay_status || !@relay_status.connected) do %>
            <div class="mt-4 p-3 bg-warning/10 rounded-lg">
              <div class="flex items-center justify-between">
                <span class="text-sm text-warning font-medium">Connection issue detected</span>
                <button
                  class="btn btn-sm btn-warning btn-outline"
                  phx-click="reconnect_relay"
                  phx-target={@myself}
                >
                  <.icon name="hero-arrow-path" class="w-4 h-4" /> Retry
                </button>
              </div>
              <p class="text-xs text-base-content/60 mt-2">
                Unable to connect to relay at <code class="font-mono bg-base-300 px-1 rounded">{@relay_url}</code>
              </p>
            </div>
          <% end %>
        </div>
      </div>

      <%= if @ra_config && @ra_config.enabled do %>
        <%!-- Pair New Device Section --%>
        <div class="card bg-base-200">
          <div class="card-body">
            <h3 class="font-semibold text-lg mb-2">Pair New Device</h3>

            <%= if @claim_code do %>
              <%!-- Active Pairing Code --%>
              <div class="flex flex-col items-center py-6">
                <p class="text-sm text-base-content/70 mb-4">
                  Enter this code in your mobile app
                </p>
                <div class="flex items-center gap-3 mb-3">
                  <code class="text-4xl font-bold tracking-[0.3em] bg-base-300 px-6 py-3 rounded-lg">
                    {@claim_code}
                  </code>
                  <button
                    class="btn btn-ghost btn-sm"
                    phx-click="copy_claim_code"
                    phx-target={@myself}
                    onclick={"navigator.clipboard.writeText('#{@claim_code}')"}
                    title="Copy code"
                  >
                    <.icon name="hero-clipboard" class="w-5 h-5" />
                  </button>
                </div>
                <div class="flex items-center gap-2 text-sm text-base-content/60">
                  <.icon name="hero-clock" class="w-4 h-4" />
                  <span>Expires in {format_countdown(@countdown_seconds)}</span>
                </div>
              </div>

              <div class="flex justify-center">
                <button
                  class="btn btn-ghost btn-sm"
                  phx-click="generate_claim_code"
                  phx-target={@myself}
                >
                  Generate new code
                </button>
              </div>
            <% else %>
              <%!-- Generate Code Prompt --%>
              <div class="flex flex-col items-center py-6">
                <p class="text-sm text-base-content/70 mb-4 text-center max-w-md">
                  Generate a temporary code to link your phone or tablet to this server
                </p>
                <button
                  class="btn btn-primary"
                  phx-click="generate_claim_code"
                  phx-target={@myself}
                >
                  <.icon name="hero-qr-code" class="w-5 h-5" /> Generate Pairing Code
                </button>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Connected Devices --%>
        <div class="card bg-base-200">
          <div class="card-body">
            <h3 class="font-semibold text-lg mb-4">Your Devices</h3>

            <%= if @devices == [] do %>
              <div class="text-center py-8 text-base-content/60">
                <.icon name="hero-device-phone-mobile" class="w-12 h-12 mx-auto mb-3 opacity-40" />
                <p>No devices paired yet</p>
                <p class="text-sm mt-1">Generate a pairing code above to connect your first device</p>
              </div>
            <% else %>
              <div class="space-y-3">
                <%= for device <- @devices do %>
                  <div class={[
                    "flex items-center justify-between p-4 rounded-lg",
                    if(RemoteAccess.RemoteDevice.revoked?(device),
                      do: "bg-base-300/50 opacity-60",
                      else: "bg-base-300"
                    )
                  ]}>
                    <div class="flex items-center gap-4">
                      <div class={[
                        "w-10 h-10 rounded-full flex items-center justify-center",
                        status_icon_class(device)
                      ]}>
                        <.icon name={platform_icon(device.platform)} class="w-5 h-5" />
                      </div>
                      <div>
                        <div class="font-medium">{device.device_name}</div>
                        <div class="text-sm text-base-content/60">
                          <%= cond do %>
                            <% RemoteAccess.RemoteDevice.revoked?(device) -> %>
                              <span class="text-error">Access revoked</span>
                            <% is_recent_activity?(device.last_seen_at) -> %>
                              Last active {format_relative_time(device.last_seen_at)}
                            <% true -> %>
                              Inactive since {format_datetime(device.last_seen_at)}
                          <% end %>
                        </div>
                      </div>
                    </div>
                    <div class="dropdown dropdown-end">
                      <label tabindex="0" class="btn btn-ghost btn-sm btn-circle">
                        <.icon name="hero-ellipsis-vertical" class="w-5 h-5" />
                      </label>
                      <ul
                        tabindex="0"
                        class="dropdown-content z-[1] menu p-2 shadow bg-base-100 rounded-box w-48"
                      >
                        <%= if is_nil(device.revoked_at) do %>
                          <li>
                            <button
                              phx-click="open_revoke_modal"
                              phx-target={@myself}
                              phx-value-id={device.id}
                              class="text-warning"
                            >
                              <.icon name="hero-no-symbol" class="w-4 h-4" /> Revoke Access
                            </button>
                          </li>
                        <% end %>
                        <li>
                          <button
                            phx-click="open_delete_modal"
                            phx-target={@myself}
                            phx-value-id={device.id}
                            class="text-error"
                          >
                            <.icon name="hero-trash" class="w-4 h-4" /> Remove Device
                          </button>
                        </li>
                      </ul>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Advanced Settings (Collapsible) --%>
        <div class="collapse collapse-arrow bg-base-200">
          <input
            type="checkbox"
            checked={@show_advanced}
            phx-click="toggle_advanced"
            phx-target={@myself}
          />
          <div class="collapse-title font-semibold">
            Advanced Settings
          </div>
          <div class="collapse-content">
            <div class="space-y-4 pt-2">
              <%!-- Direct URLs --%>
              <div>
                <div class="flex items-center justify-between mb-2">
                  <div>
                    <p class="font-medium text-sm">Direct Connection URLs</p>
                    <p class="text-xs text-base-content/60">
                      Optional URLs for direct connections (bypassing relay)
                    </p>
                  </div>
                  <button
                    class="btn btn-sm btn-ghost"
                    phx-click="open_add_url_modal"
                    phx-target={@myself}
                  >
                    <.icon name="hero-plus" class="w-4 h-4" /> Add
                  </button>
                </div>
                <%= if @ra_config.direct_urls && @ra_config.direct_urls != [] do %>
                  <div class="space-y-1">
                    <%= for url <- @ra_config.direct_urls do %>
                      <div class="flex items-center justify-between p-2 bg-base-300 rounded text-sm">
                        <code class="font-mono text-xs">{url}</code>
                        <button
                          class="btn btn-xs btn-ghost text-error"
                          phx-click="remove_direct_url"
                          phx-target={@myself}
                          phx-value-url={url}
                        >
                          <.icon name="hero-x-mark" class="w-3 h-3" />
                        </button>
                      </div>
                    <% end %>
                  </div>
                <% else %>
                  <p class="text-xs text-base-content/50 italic">No direct URLs configured</p>
                <% end %>
              </div>

              <div class="divider my-2"></div>

              <%!-- Technical Info --%>
              <div>
                <p class="font-medium text-sm mb-2">Connection Details</p>
                <div class="grid gap-2 text-xs">
                  <div class="flex justify-between p-2 bg-base-300 rounded">
                    <span class="text-base-content/60">Instance ID</span>
                    <div class="flex items-center gap-1">
                      <code class="font-mono">{String.slice(@ra_config.instance_id, 0..11)}...</code>
                      <button
                        class="btn btn-xs btn-ghost"
                        phx-click="copy_instance_id"
                        phx-target={@myself}
                        onclick={"navigator.clipboard.writeText('#{@ra_config.instance_id}')"}
                      >
                        <.icon name="hero-clipboard" class="w-3 h-3" />
                      </button>
                    </div>
                  </div>
                  <div class="flex justify-between p-2 bg-base-300 rounded">
                    <span class="text-base-content/60">Relay Server</span>
                    <code class="font-mono">{@relay_url}</code>
                  </div>
                  <div class="flex justify-between p-2 bg-base-300 rounded">
                    <span class="text-base-content/60">Status</span>
                    <span class={
                      if @relay_status && @relay_status.registered,
                        do: "text-success",
                        else: "text-warning"
                    }>
                      {if @relay_status && @relay_status.registered,
                        do: "Registered",
                        else: "Not registered"}
                    </span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      <% else %>
        <%!-- Disabled State Info --%>
        <div class="card bg-base-200">
          <div class="card-body text-center py-12">
            <.icon
              name="hero-device-phone-mobile"
              class="w-16 h-16 mx-auto mb-4 text-base-content/30"
            />
            <h3 class="font-semibold text-lg mb-2">Connect from Anywhere</h3>
            <p class="text-base-content/70 max-w-md mx-auto">
              Enable remote access to use the Mydia mobile app on your phone or tablet,
              even when you're away from home.
            </p>
          </div>
        </div>
      <% end %>

      <%!-- Revoke Device Modal --%>
      <%= if @show_revoke_modal && @selected_device do %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg mb-4">Revoke Access?</h3>
            <p class="text-base-content/70 mb-4">
              <strong>{@selected_device.device_name}</strong> will be disconnected and won't be able
              to access your library until you pair it again.
            </p>

            <div class="modal-action">
              <button
                type="button"
                phx-click="close_revoke_modal"
                phx-target={@myself}
                class="btn btn-ghost"
              >
                Cancel
              </button>
              <button phx-click="submit_revoke" phx-target={@myself} class="btn btn-warning">
                Revoke Access
              </button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="close_revoke_modal" phx-target={@myself}></div>
        </div>
      <% end %>

      <%!-- Delete Device Modal --%>
      <%= if @show_delete_modal && @device_to_delete do %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg mb-4">Remove Device?</h3>
            <p class="text-base-content/70 mb-4">
              <strong>{@device_to_delete.device_name}</strong> will be removed from your account.
              You'll need to pair it again to reconnect.
            </p>

            <div class="modal-action">
              <button
                type="button"
                phx-click="close_delete_modal"
                phx-target={@myself}
                class="btn btn-ghost"
              >
                Cancel
              </button>
              <button phx-click="submit_delete" phx-target={@myself} class="btn btn-error">
                Remove Device
              </button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="close_delete_modal" phx-target={@myself}></div>
        </div>
      <% end %>

      <%!-- Add Direct URL Modal --%>
      <%= if @show_add_url_modal do %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg mb-4">Add Direct URL</h3>
            <p class="text-sm text-base-content/70 mb-4">
              Add a URL where your server can be reached directly (e.g., when on the same network).
            </p>

            <div class="form-control">
              <input
                type="url"
                placeholder="https://mydia.local:4000"
                class="input input-bordered w-full"
                value={@new_url}
                phx-change="update_new_url"
                phx-target={@myself}
              />
            </div>

            <div class="modal-action">
              <button
                type="button"
                phx-click="close_add_url_modal"
                phx-target={@myself}
                class="btn btn-ghost"
              >
                Cancel
              </button>
              <button
                phx-click="add_direct_url"
                phx-target={@myself}
                class="btn btn-primary"
                disabled={@new_url == ""}
              >
                Add URL
              </button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="close_add_url_modal" phx-target={@myself}></div>
        </div>
      <% end %>
    </div>
    """
  end

  ## Event Handlers

  @impl true
  def handle_event("toggle_remote_access", params, socket) do
    require Logger
    Logger.warning("toggle_remote_access called with params: #{inspect(params)}")
    Logger.warning("ra_config: #{inspect(socket.assigns.ra_config)}")
    enabled_str = Map.get(params, "enabled", "false")
    enabled = enabled_str == "true"
    Logger.warning("Parsed enabled: #{enabled}")
    config = socket.assigns.ra_config

    with {:ok, socket} <- maybe_initialize_keypair(socket, config, enabled),
         {:ok, updated_config} <- RemoteAccess.toggle_remote_access(enabled) do
      {:noreply,
       socket
       |> assign(:ra_config, updated_config)
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
        expires_at = claim.expires_at
        now = DateTime.utc_now()
        seconds = DateTime.diff(expires_at, now, :second)

        # Schedule the first countdown tick via the parent LiveView
        send(self(), {:remote_access_countdown_tick, socket.assigns.id})

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
    {:noreply, put_flash(socket, :info, "Code copied to clipboard")}
  end

  def handle_event("copy_public_key", _params, socket) do
    {:noreply, put_flash(socket, :info, "Public key copied to clipboard")}
  end

  def handle_event("copy_instance_id", _params, socket) do
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
    config = socket.assigns.ra_config
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
    config = socket.assigns.ra_config
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
        # Request refresh via parent
        send(self(), {:remote_access_refresh_relay, socket.assigns.id})

        {:noreply,
         socket
         |> put_flash(:info, "Relay reconnection initiated")}

      {:error, :not_running} ->
        {:noreply,
         socket
         |> put_flash(:error, "Relay service is not running. Check configuration and restart.")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to reconnect relay")}
    end
  end

  def handle_event("toggle_advanced", _params, socket) do
    {:noreply, assign(socket, :show_advanced, !socket.assigns.show_advanced)}
  end

  # Catch-all for debugging unknown events
  def handle_event(event, params, socket) do
    require Logger
    Logger.warning("UNKNOWN EVENT in RemoteAccessComponent: #{event}, params: #{inspect(params)}")
    {:noreply, socket}
  end

  ## Countdown update (called from parent via send_update)

  def handle_countdown_tick(socket) do
    claim_expires_at = socket.assigns.claim_expires_at

    if claim_expires_at do
      now = DateTime.utc_now()
      seconds_remaining = DateTime.diff(claim_expires_at, now, :second)

      if seconds_remaining > 0 do
        # Schedule the next tick via the parent
        send(self(), {:remote_access_countdown_tick, socket.assigns.id})

        assign(socket, :countdown_seconds, seconds_remaining)
      else
        socket
        |> assign(:claim_code, nil)
        |> assign(:claim_expires_at, nil)
        |> assign(:countdown_seconds, 0)
        |> put_flash(:info, "Pairing code expired")
      end
    else
      socket
    end
  end

  ## Private Helpers

  defp maybe_initialize_keypair(socket, nil, true) do
    case RemoteAccess.initialize_keypair() do
      {:ok, new_config} ->
        {:ok, assign(socket, :ra_config, new_config)}

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
    assign(socket, :ra_config, config)
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

  defp is_recent_activity?(nil), do: false

  defp is_recent_activity?(last_seen) do
    seven_days_ago = DateTime.utc_now() |> DateTime.add(-7, :day)
    DateTime.compare(last_seen, seven_days_ago) == :gt
  end

  defp platform_icon("ios"), do: "hero-device-phone-mobile"
  defp platform_icon("android"), do: "hero-device-phone-mobile"
  defp platform_icon("web"), do: "hero-computer-desktop"
  defp platform_icon(_), do: "hero-device-tablet"

  defp status_icon_class(%RemoteAccess.RemoteDevice{revoked_at: revoked})
       when not is_nil(revoked) do
    "bg-error/20 text-error"
  end

  defp status_icon_class(%RemoteAccess.RemoteDevice{last_seen_at: last_seen}) do
    if is_recent_activity?(last_seen) do
      "bg-success/20 text-success"
    else
      "bg-base-content/10 text-base-content/50"
    end
  end

  defp format_relative_time(nil), do: "never"

  defp format_relative_time(%DateTime{} = dt) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, dt, :second)

    cond do
      diff_seconds < 60 -> "just now"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)} min ago"
      diff_seconds < 86400 -> "#{div(diff_seconds, 3600)} hours ago"
      diff_seconds < 604_800 -> "#{div(diff_seconds, 86400)} days ago"
      true -> format_datetime(dt)
    end
  end
end
