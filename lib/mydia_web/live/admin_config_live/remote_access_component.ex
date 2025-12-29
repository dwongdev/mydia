defmodule MydiaWeb.AdminConfigLive.RemoteAccessComponent do
  @moduledoc """
  LiveComponent for managing remote access settings.

  This component provides an inline interface for configuring remote access,
  managing paired devices, and generating pairing codes.
  """
  use MydiaWeb, :live_component

  alias Mydia.RemoteAccess

  require Logger

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

  def update(%{port_check_result: status} = _assigns, socket) do
    # Handle port check result from async task
    {:ok, assign(socket, port_status: status, checking_port: false)}
  end

  def update(%{start_port_check: true} = _assigns, socket) do
    # Start async port check
    socket = assign(socket, checking_port: true)
    public_addr = get_public_address()

    if public_addr.ip do
      component_id = socket.assigns.id
      # Capture the parent LiveView pid before starting the task
      parent_pid = self()

      Task.start(fn ->
        result = check_port_accessible(public_addr.ip, public_addr.port)
        send(parent_pid, {:port_check_complete, component_id, result})
      end)
    else
      # No public IP - mark as unknown immediately
      send(self(), {:port_check_complete, socket.assigns.id, :unknown})
    end

    {:ok, socket}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:claim_code, fn -> nil end)
      |> assign_new(:claim_expires_at, fn -> nil end)
      |> assign_new(:countdown_seconds, fn -> 0 end)
      |> assign_new(:pairing_error, fn -> nil end)
      |> assign_new(:show_revoke_modal, fn -> false end)
      |> assign_new(:selected_device, fn -> nil end)
      |> assign_new(:show_delete_modal, fn -> false end)
      |> assign_new(:device_to_delete, fn -> nil end)
      |> assign_new(:show_add_url_modal, fn -> false end)
      |> assign_new(:new_url, fn -> "" end)
      |> assign_new(:show_advanced, fn -> false end)
      |> assign_new(:port_status, fn -> :unknown end)
      |> assign_new(:checking_port, fn -> false end)
      # Read relay URL from environment, not database
      |> assign(:relay_url, Mydia.Metadata.metadata_relay_url())
      |> load_config()
      |> load_devices()
      |> load_relay_status()

    # Subscribe to claim expiry notifications on first mount
    if connected?(socket) and is_nil(assigns[:subscribed]) do
      Phoenix.PubSub.subscribe(Mydia.PubSub, "remote_access:claims")
      # Trigger initial port check if enabled
      send(self(), {:check_port_status, socket.assigns.id})
    end

    {:ok, assign(socket, :subscribed, true)}
  end

  @impl true
  def render(assigns) do
    relay_ready =
      assigns.ra_config && assigns.ra_config.enabled && assigns.relay_status &&
        assigns.relay_status.connected && assigns.relay_status.registered

    # Get local and public address info
    local_addr = get_local_address()
    public_addr = get_public_address()

    assigns =
      assigns
      |> assign(:relay_ready, relay_ready)
      |> assign(:local_addr, local_addr)
      |> assign(:public_addr, public_addr)

    ~H"""
    <div class="p-4 sm:p-6 space-y-6">
      <%!-- Header with toggle --%>
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <h2 class="text-lg font-semibold flex items-center gap-2">
          <.icon name="hero-signal" class="w-5 h-5 opacity-60" /> Remote Access
          <%= if @ra_config && @ra_config.enabled do %>
            <span class={[
              "badge badge-sm",
              if(@relay_ready, do: "badge-success", else: "badge-warning")
            ]}>
              <%= cond do %>
                <% @relay_ready -> %>
                  Connected
                <% @relay_status && @relay_status.connected -> %>
                  Registering...
                <% @relay_status -> %>
                  Connecting...
                <% true -> %>
                  Offline
              <% end %>
            </span>
          <% else %>
            <span class="badge badge-ghost badge-sm">Disabled</span>
          <% end %>
        </h2>
        <label class="label cursor-pointer gap-3">
          <span class="label-text text-sm">
            {if @ra_config && @ra_config.enabled, do: "Enabled", else: "Disabled"}
          </span>
          <input
            type="checkbox"
            id="remote-access-toggle"
            class="toggle toggle-primary"
            checked={@ra_config && @ra_config.enabled}
            phx-click="toggle_remote_access"
            phx-target={@myself}
            phx-value-enabled={to_string(!(@ra_config && @ra_config.enabled))}
          />
        </label>
      </div>

      <%!-- Prominent Connection Status Display --%>
      <%= if @ra_config && @ra_config.enabled do %>
        <div class="bg-base-200 rounded-box p-4 sm:p-5">
          <div class="flex flex-col lg:flex-row lg:items-center gap-4">
            <%!-- Connection Info --%>
            <div class="flex-1 flex flex-col sm:flex-row items-start sm:items-center gap-3 sm:gap-4">
              <%!-- Local Address --%>
              <div class="flex items-center gap-2">
                <div class="w-8 h-8 rounded-full bg-base-300 flex items-center justify-center shrink-0">
                  <.icon name="hero-home" class="w-4 h-4 opacity-60" />
                </div>
                <div>
                  <div class="text-xs text-base-content/50 uppercase tracking-wide">Local</div>
                  <div class="font-mono text-sm font-medium">
                    <%= if @local_addr.ip do %>
                      {@local_addr.ip}:{@local_addr.port}
                    <% else %>
                      <span class="text-base-content/50">Unknown</span>
                    <% end %>
                  </div>
                </div>
              </div>

              <%!-- Arrow --%>
              <div class="hidden sm:flex items-center text-base-content/30">
                <.icon name="hero-arrows-right-left" class="w-5 h-5" />
              </div>

              <%!-- Public Address --%>
              <div class="flex items-center gap-2">
                <div class="w-8 h-8 rounded-full bg-base-300 flex items-center justify-center shrink-0">
                  <.icon name="hero-globe-alt" class="w-4 h-4 opacity-60" />
                </div>
                <div>
                  <div class="text-xs text-base-content/50 uppercase tracking-wide">Public</div>
                  <div class="font-mono text-sm font-medium">
                    <%= if @public_addr.ip do %>
                      {@public_addr.ip}:{@public_addr.port}
                    <% else %>
                      <span class="text-base-content/50">Not detected</span>
                    <% end %>
                  </div>
                </div>
              </div>
            </div>

            <%!-- Status Badge --%>
            <div class="shrink-0 flex items-center gap-2">
              <%= cond do %>
                <% @checking_port -> %>
                  <div class="flex items-center gap-2 px-4 py-2 rounded-full bg-base-300 border border-base-content/20">
                    <span class="loading loading-spinner loading-xs"></span>
                    <span class="font-semibold text-base-content/70 text-sm">Checking...</span>
                  </div>
                <% @port_status == :open -> %>
                  <div class="flex items-center gap-2 px-4 py-2 rounded-full bg-success/10 border border-success/30">
                    <span class="relative flex h-3 w-3">
                      <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-success opacity-75">
                      </span>
                      <span class="relative inline-flex rounded-full h-3 w-3 bg-success"></span>
                    </span>
                    <span class="font-semibold text-success text-sm">Fully Accessible</span>
                  </div>
                <% @port_status == :closed -> %>
                  <div class="flex items-center gap-2 px-4 py-2 rounded-full bg-warning/10 border border-warning/30">
                    <span class="w-3 h-3 rounded-full bg-warning"></span>
                    <span class="font-semibold text-warning text-sm">Relay Only</span>
                  </div>
                <% not @relay_ready -> %>
                  <div class={[
                    "flex items-center gap-2 px-4 py-2 rounded-full border",
                    if(@relay_status && @relay_status.connected,
                      do: "bg-warning/10 border-warning/30",
                      else: "bg-error/10 border-error/30"
                    )
                  ]}>
                    <span class={[
                      "w-3 h-3 rounded-full",
                      if(@relay_status && @relay_status.connected, do: "bg-warning", else: "bg-error")
                    ]}>
                    </span>
                    <span class={[
                      "font-semibold text-sm",
                      if(@relay_status && @relay_status.connected,
                        do: "text-warning",
                        else: "text-error"
                      )
                    ]}>
                      <%= cond do %>
                        <% @relay_status && @relay_status.connected -> %>
                          Registering...
                        <% @relay_status -> %>
                          Connecting...
                        <% true -> %>
                          Relay Offline
                      <% end %>
                    </span>
                  </div>
                <% true -> %>
                  <%!-- Unknown status - show neutral with check button --%>
                  <div class="flex items-center gap-2 px-4 py-2 rounded-full bg-base-300 border border-base-content/20">
                    <span class="w-3 h-3 rounded-full bg-base-content/30"></span>
                    <span class="font-semibold text-base-content/70 text-sm">Unknown</span>
                  </div>
              <% end %>
              <%!-- Refresh button --%>
              <%= if @relay_ready and not @checking_port do %>
                <button
                  class="btn btn-ghost btn-sm btn-circle"
                  phx-click="check_port"
                  phx-target={@myself}
                  title="Check accessibility"
                >
                  <.icon name="hero-arrow-path" class="w-4 h-4" />
                </button>
              <% end %>
            </div>
          </div>

          <%!-- Relay-only warning when port is not accessible --%>
          <%= if @port_status == :closed do %>
            <div class="mt-3 flex items-center gap-2 text-sm text-warning">
              <.icon name="hero-exclamation-triangle" class="w-4 h-4 shrink-0" />
              <span>
                Media playback requires direct connection. Set up port forwarding to enable.
              </span>
            </div>
          <% end %>
        </div>
      <% end %>

      <%!-- Connection warning when enabled but not connected --%>
      <%= if @ra_config && @ra_config.enabled && (!@relay_status || !@relay_status.connected) do %>
        <div class="alert alert-warning">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
          <div class="flex-1">
            <span>Unable to connect to relay at </span>
            <code class="font-mono text-xs">{@relay_url}</code>
          </div>
          <button
            class="btn btn-sm btn-warning btn-outline"
            phx-click="reconnect_relay"
            phx-target={@myself}
          >
            <.icon name="hero-arrow-path" class="w-4 h-4" /> Retry
          </button>
        </div>
      <% end %>

      <%= if @ra_config && @ra_config.enabled do %>
        <%!-- Pair New Device - only shown when relay is ready --%>
        <%= if @relay_ready do %>
          <div class="space-y-3">
            <h3 class="text-sm font-medium text-base-content/70 flex items-center gap-2">
              <.icon name="hero-qr-code" class="w-4 h-4" /> Pair New Device
            </h3>
            <div class="bg-base-200 rounded-box p-4">
              <div class="flex flex-col sm:flex-row gap-6 items-center sm:items-start">
                <%!-- QR Code --%>
                <%= if qr_svg = generate_qr_code(@ra_config, @relay_url) do %>
                  <div class="shrink-0">
                    <div class="p-2 bg-white rounded-lg">
                      {Phoenix.HTML.raw(qr_svg)}
                    </div>
                    <p class="text-xs text-base-content/50 mt-2 text-center">Scan with camera</p>
                  </div>
                <% end %>

                <%!-- Pairing Code --%>
                <div class="flex-1 text-center sm:text-left">
                  <%= if @claim_code do %>
                    <p class="text-sm text-base-content/60 mb-2">Or enter this code:</p>
                    <div class="flex items-center gap-2 justify-center sm:justify-start">
                      <code class="text-2xl font-bold tracking-[0.25em] bg-base-300 px-4 py-2 rounded-lg font-mono">
                        {@claim_code}
                      </code>
                      <button
                        class="btn btn-ghost btn-sm btn-square"
                        phx-click="copy_claim_code"
                        phx-target={@myself}
                        onclick={"navigator.clipboard.writeText('#{@claim_code}')"}
                        title="Copy"
                      >
                        <.icon name="hero-clipboard" class="w-4 h-4" />
                      </button>
                    </div>
                    <div class="flex items-center gap-2 mt-2 text-sm text-base-content/50 justify-center sm:justify-start">
                      <.icon name="hero-clock" class="w-4 h-4" />
                      <span>
                        Expires in
                        <span class="font-mono">{format_countdown(@countdown_seconds)}</span>
                      </span>
                    </div>
                    <button
                      id="regenerate-pairing-code-btn"
                      class="btn btn-ghost btn-xs mt-2"
                      phx-click="generate_claim_code"
                      phx-target={@myself}
                      phx-disable-with="..."
                    >
                      <.icon name="hero-arrow-path" class="w-3 h-3" /> New Code
                    </button>
                  <% else %>
                    <%= if @pairing_error do %>
                      <div class="alert alert-error alert-sm mb-3">
                        <.icon name="hero-exclamation-circle" class="w-4 h-4" />
                        <span class="text-sm">{@pairing_error}</span>
                      </div>
                    <% end %>
                    <p class="text-sm text-base-content/60 mb-3">
                      Generate a code to pair a new device.
                    </p>
                    <button
                      id="generate-pairing-code-btn"
                      class="btn btn-primary btn-sm"
                      phx-click="generate_claim_code"
                      phx-target={@myself}
                      phx-disable-with="Generating..."
                    >
                      <.icon name="hero-key" class="w-4 h-4" /> Generate Code
                    </button>
                  <% end %>
                </div>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Devices Section --%>
        <div class="space-y-3">
          <h3 class="text-sm font-medium text-base-content/70 flex items-center gap-2">
            <.icon name="hero-device-phone-mobile" class="w-4 h-4" /> Paired Devices
            <span class="badge badge-ghost badge-sm">{length(@devices)}</span>
          </h3>

          <%= if @devices == [] do %>
            <div class="alert">
              <.icon name="hero-information-circle" class="w-5 h-5 opacity-60" />
              <span>
                No devices paired yet. Generate a pairing code above to connect your first device.
              </span>
            </div>
          <% else %>
            <div class="bg-base-200 rounded-box divide-y divide-base-300">
              <%= for device <- @devices do %>
                <div class={["p-3 sm:p-4", RemoteAccess.RemoteDevice.revoked?(device) && "opacity-50"]}>
                  <div class="flex flex-col sm:flex-row sm:items-center gap-3">
                    <div class="flex-1 min-w-0">
                      <div class="font-semibold flex items-center gap-2 flex-wrap">
                        <.icon name={platform_icon(device.platform)} class="w-4 h-4 opacity-60" />
                        {device.device_name}
                        <%= if RemoteAccess.RemoteDevice.revoked?(device) do %>
                          <span class="badge badge-error badge-xs">Revoked</span>
                        <% end %>
                      </div>
                      <div class="text-xs opacity-60 mt-0.5">
                        <%= cond do %>
                          <% RemoteAccess.RemoteDevice.revoked?(device) -> %>
                            Access revoked
                          <% is_recent_activity?(device.last_seen_at) -> %>
                            Last active {format_relative_time(device.last_seen_at)}
                          <% true -> %>
                            Inactive since {format_datetime(device.last_seen_at)}
                        <% end %>
                      </div>
                    </div>
                    <div class="flex items-center gap-2">
                      <span class={[
                        "badge badge-sm",
                        if(is_recent_activity?(device.last_seen_at) && is_nil(device.revoked_at),
                          do: "badge-success",
                          else: "badge-ghost"
                        )
                      ]}>
                        {if is_recent_activity?(device.last_seen_at) && is_nil(device.revoked_at),
                          do: "Active",
                          else: "Inactive"}
                      </span>
                      <div class="join">
                        <%= if is_nil(device.revoked_at) do %>
                          <button
                            class="btn btn-sm btn-ghost join-item"
                            phx-click="open_revoke_modal"
                            phx-target={@myself}
                            phx-value-id={device.id}
                            title="Revoke Access"
                          >
                            <.icon name="hero-no-symbol" class="w-4 h-4" />
                          </button>
                        <% end %>
                        <button
                          class="btn btn-sm btn-ghost join-item text-error"
                          phx-click="open_delete_modal"
                          phx-target={@myself}
                          phx-value-id={device.id}
                          title="Remove Device"
                        >
                          <.icon name="hero-trash" class="w-4 h-4" />
                        </button>
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>

        <%!-- Advanced Settings --%>
        <div class="space-y-3">
          <button
            class="text-sm font-medium text-base-content/70 flex items-center gap-2 hover:text-base-content transition-colors"
            phx-click="toggle_advanced"
            phx-target={@myself}
          >
            <.icon
              name={if @show_advanced, do: "hero-chevron-down", else: "hero-chevron-right"}
              class="w-4 h-4"
            /> Advanced Settings
          </button>

          <%= if @show_advanced do %>
            <div class="bg-base-200 rounded-box divide-y divide-base-300">
              <%!-- Public Port --%>
              <form phx-submit="update_public_port" phx-target={@myself} class="p-3 sm:p-4">
                <div class="flex flex-col sm:flex-row sm:items-center gap-3">
                  <div class="flex-1 min-w-0">
                    <div class="font-medium text-sm">Public Port</div>
                    <div class="text-xs opacity-60">Override if external port differs (NAT)</div>
                  </div>
                  <div class="flex items-center gap-2">
                    <input
                      type="number"
                      name="public_port"
                      placeholder="Auto"
                      class="input input-sm input-bordered w-24 text-center font-mono"
                      value={@ra_config.public_port}
                      min="1"
                      max="65535"
                    />
                    <button type="submit" class="btn btn-sm btn-primary">Save</button>
                  </div>
                </div>
              </form>

              <%!-- Direct URLs --%>
              <div class="p-3 sm:p-4">
                <div class="flex flex-col sm:flex-row sm:items-center gap-3 mb-2">
                  <div class="flex-1 min-w-0">
                    <div class="font-medium text-sm">Direct URLs</div>
                    <div class="text-xs opacity-60">Bypass relay when on same network</div>
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
                  <div class="space-y-1 mt-2">
                    <%= for url <- @ra_config.direct_urls do %>
                      <div class="flex items-center justify-between p-2 bg-base-300 rounded text-sm">
                        <code class="font-mono text-xs truncate">{url}</code>
                        <button
                          class="btn btn-xs btn-ghost text-error shrink-0"
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
                  <p class="text-xs text-base-content/50 italic mt-2">None configured</p>
                <% end %>
              </div>

              <%!-- Connection Info --%>
              <div class="p-3 sm:p-4">
                <div class="font-medium text-sm mb-2">Connection Details</div>
                <div class="grid gap-1.5 text-xs">
                  <div class="flex justify-between items-center">
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
                  <div class="flex justify-between items-center">
                    <span class="text-base-content/60">Relay</span>
                    <code class="font-mono">{@relay_url}</code>
                  </div>
                  <div class="flex justify-between items-center">
                    <span class="text-base-content/60">Status</span>
                    <span class={if(@relay_ready, do: "text-success", else: "text-warning")}>
                      {if @relay_ready, do: "Registered", else: "Not registered"}
                    </span>
                  </div>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      <% else %>
        <%!-- Disabled state --%>
        <div class="alert">
          <.icon name="hero-device-phone-mobile" class="w-6 h-6 opacity-40" />
          <div>
            <div class="font-medium">Connect from Anywhere</div>
            <div class="text-sm opacity-70">
              Enable remote access to use the Mydia mobile app on your phone or tablet.
            </div>
          </div>
        </div>
      <% end %>

      <%!-- Revoke Device Modal --%>
      <%= if @show_revoke_modal && @selected_device do %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg mb-4">Revoke Access?</h3>
            <p class="text-base-content/70">
              <strong>{@selected_device.device_name}</strong>
              will be disconnected and won't be able to access your library until paired again.
            </p>
            <div class="modal-action">
              <button phx-click="close_revoke_modal" phx-target={@myself} class="btn btn-ghost">
                Cancel
              </button>
              <button phx-click="submit_revoke" phx-target={@myself} class="btn btn-warning">
                Revoke
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
            <p class="text-base-content/70">
              <strong>{@device_to_delete.device_name}</strong>
              will be removed. You'll need to pair it again to reconnect.
            </p>
            <div class="modal-action">
              <button phx-click="close_delete_modal" phx-target={@myself} class="btn btn-ghost">
                Cancel
              </button>
              <button phx-click="submit_delete" phx-target={@myself} class="btn btn-error">
                Remove
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
              Add a URL where your server can be reached directly (e.g., on the same network).
            </p>
            <input
              type="url"
              placeholder="https://mydia.local:4000"
              class="input input-bordered w-full"
              value={@new_url}
              phx-change="update_new_url"
              phx-target={@myself}
            />
            <div class="modal-action">
              <button phx-click="close_add_url_modal" phx-target={@myself} class="btn btn-ghost">
                Cancel
              </button>
              <button
                phx-click="add_direct_url"
                phx-target={@myself}
                class="btn btn-primary"
                disabled={@new_url == ""}
              >
                Add
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
    enabled_str = Map.get(params, "enabled", "false")
    enabled = enabled_str == "true"
    config = socket.assigns.ra_config

    with {:ok, socket} <- maybe_initialize_keypair(socket, config, enabled),
         {:ok, updated_config} <- RemoteAccess.toggle_remote_access(enabled),
         :ok <- maybe_start_or_stop_relay(enabled) do
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

      {:error, :remote_access_not_configured} ->
        {:noreply,
         socket
         |> load_relay_status()
         |> put_flash(:error, "Failed to start relay: remote access not fully configured")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to update remote access setting")}
    end
  end

  def handle_event("generate_claim_code", _params, socket) do
    Logger.debug("Generate claim code button clicked")
    {:noreply, do_generate_claim_code(socket)}
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
    # First, try to start the relay if it's not running
    case RemoteAccess.start_relay() do
      :ok ->
        # Request refresh via parent
        send(self(), {:remote_access_refresh_relay, socket.assigns.id})

        {:noreply,
         socket
         |> load_relay_status()
         |> put_flash(:info, "Relay connection initiated")}

      {:error, :remote_access_not_configured} ->
        {:noreply,
         socket
         |> put_flash(:error, "Remote access is not fully configured")}

      {:error, :remote_access_disabled} ->
        {:noreply,
         socket
         |> put_flash(:error, "Remote access is disabled")}

      {:error, reason} ->
        Logger.error("Failed to start relay: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(:error, "Failed to connect to relay service")}
    end
  end

  def handle_event("toggle_advanced", _params, socket) do
    {:noreply, assign(socket, :show_advanced, !socket.assigns.show_advanced)}
  end

  def handle_event("check_port", _params, socket) do
    send(self(), {:check_port_status, socket.assigns.id})
    {:noreply, assign(socket, checking_port: true)}
  end

  def handle_event("update_public_port", %{"public_port" => port_str}, socket) do
    # Parse the port string, treating empty string as nil (clear the setting)
    port =
      case String.trim(port_str) do
        "" -> nil
        str -> String.to_integer(str)
      end

    case RemoteAccess.update_public_port(port) do
      {:ok, _config} ->
        {:noreply,
         socket
         |> load_config()
         |> put_flash(:info, "Public port updated successfully")}

      {:error, :invalid_port} ->
        {:noreply,
         socket
         |> put_flash(:error, "Invalid port number. Must be between 1 and 65535.")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to update public port")}
    end
  rescue
    ArgumentError ->
      {:noreply,
       socket
       |> put_flash(:error, "Invalid port number. Must be a valid integer.")}
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

  ## Claim code generation (called from parent via send_update)

  def do_generate_claim_code(socket) do
    user_id = socket.assigns.current_user.id
    relay_status = socket.assigns.relay_status

    Logger.debug(
      "Generating pairing code for user #{user_id}, relay_status=#{inspect(relay_status)}"
    )

    case RemoteAccess.generate_claim_code(user_id) do
      {:ok, claim} ->
        Logger.info("Pairing code generated successfully: #{claim.code}")
        expires_at = claim.expires_at
        now = DateTime.utc_now()
        seconds = DateTime.diff(expires_at, now, :second)

        # Schedule the first countdown tick via the parent LiveView
        send(self(), {:remote_access_countdown_tick, socket.assigns.id})

        socket
        |> assign(:pairing_error, nil)
        |> assign(:claim_code, claim.code)
        |> assign(:claim_expires_at, expires_at)
        |> assign(:countdown_seconds, max(0, seconds))

      {:error, :relay_not_connected} ->
        Logger.warning("Failed to generate pairing code: relay service not connected")

        assign(
          socket,
          :pairing_error,
          "Relay service is not connected. Check your relay configuration."
        )

      {:error, :relay_timeout} ->
        Logger.warning("Failed to generate pairing code: relay service timeout after 5s")

        assign(
          socket,
          :pairing_error,
          "Relay service did not respond in time. Please try again."
        )

      {:error, {:relay_error, reason}} ->
        Logger.error("Failed to generate pairing code: relay error - #{inspect(reason)}")

        assign(
          socket,
          :pairing_error,
          "Relay service error. Please try again later."
        )

      {:error, changeset} ->
        Logger.error("Failed to generate pairing code: database error - #{inspect(changeset)}")

        assign(socket, :pairing_error, "Database error. Please try again.")
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

  defp maybe_start_or_stop_relay(true), do: RemoteAccess.start_relay()
  defp maybe_start_or_stop_relay(false), do: RemoteAccess.stop_relay()

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
      qr_code = EQRCode.encode(content)
      EQRCode.svg(qr_code, width: 180)
    else
      nil
    end
  end

  # Connection info helpers

  defp get_local_address do
    config = Application.get_env(:mydia, :direct_urls, [])
    port = Keyword.get(config, :external_port, 4000)

    case :inet.getifaddrs() do
      {:ok, interfaces} ->
        ip =
          interfaces
          |> Enum.flat_map(fn {_iface, props} ->
            props
            |> Enum.filter(fn {key, _} -> key == :addr end)
            |> Enum.map(fn {:addr, addr} -> addr end)
            |> Enum.filter(&valid_local_ip?/1)
          end)
          |> List.first()

        case ip do
          {a, b, c, d} -> %{ip: "#{a}.#{b}.#{c}.#{d}", port: port}
          _ -> %{ip: nil, port: port}
        end

      {:error, _} ->
        %{ip: nil, port: port}
    end
  end

  defp get_public_address do
    port = Mydia.RemoteAccess.DirectUrls.get_public_port()

    case Mydia.RemoteAccess.DirectUrls.detect_public_ip() do
      {:ok, ip} -> %{ip: ip, port: port}
      {:error, _} -> %{ip: nil, port: port}
    end
  end

  defp valid_local_ip?({127, _, _, _}), do: false
  defp valid_local_ip?({169, 254, _, _}), do: false
  defp valid_local_ip?({172, 17, _, _}), do: false

  defp valid_local_ip?({a, b, c, d})
       when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) and
              tuple_size({a, b, c, d}) == 4,
       do: true

  defp valid_local_ip?(_), do: false

  # Check if port is accessible from the internet using portchecker.io
  defp check_port_accessible(nil, _port), do: :unknown
  defp check_port_accessible(_ip, nil), do: :unknown

  defp check_port_accessible(ip, port) do
    url = "https://portchecker.io/api/v1/query"

    body =
      Jason.encode!(%{
        host: ip,
        ports: [port]
      })

    case Req.post(url,
           body: body,
           headers: [{"content-type", "application/json"}],
           receive_timeout: 10_000,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: %{"check" => results}}} ->
        # Results is a list like [%{"port" => 4000, "status" => true}]
        case results do
          [%{"status" => true} | _] -> :open
          [%{"status" => false} | _] -> :closed
          _ -> :unknown
        end

      {:ok, %Req.Response{body: body}} ->
        Logger.debug("Port check unexpected response: #{inspect(body)}")
        :unknown

      {:error, reason} ->
        Logger.debug("Port check failed: #{inspect(reason)}")
        :unknown
    end
  rescue
    _ -> :unknown
  end
end
