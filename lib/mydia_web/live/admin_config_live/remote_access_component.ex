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

  def update(%{refresh_p2p: true} = _assigns, socket) do
    # Handle P2P status refresh from parent
    socket =
      socket
      |> load_p2p_status()

    {:ok, socket}
  end

  def update(%{claim_consumed: consumed_code} = _assigns, socket) do
    # A claim code was used - clear the pairing UI if it matches the displayed code
    current_code = socket.assigns[:claim_code]

    if current_code && normalize_code(current_code) == normalize_code(consumed_code) do
      {:ok,
       socket
       |> assign(:claim_code, nil)
       |> assign(:claim_expires_at, nil)
       |> assign(:countdown_seconds, 0)
       |> assign(:show_pairing_modal, false)
       |> load_devices()
       |> put_flash(:info, "Device paired successfully!")}
    else
      {:ok, socket}
    end
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:claim_code, fn -> nil end)
      |> assign_new(:claim_expires_at, fn -> nil end)
      |> assign_new(:countdown_seconds, fn -> 0 end)
      |> assign_new(:claim_code_rendezvous_status, fn -> nil end)
      |> assign_new(:pairing_error, fn -> nil end)
      |> assign_new(:show_revoke_modal, fn -> false end)
      |> assign_new(:selected_device, fn -> nil end)
      |> assign_new(:show_delete_modal, fn -> false end)
      |> assign_new(:device_to_delete, fn -> nil end)
      |> assign_new(:show_pairing_modal, fn -> false end)
      |> assign_new(:show_add_url_modal, fn -> false end)
      |> assign_new(:new_url, fn -> "" end)
      |> assign_new(:show_advanced, fn -> false end)
      |> assign_new(:show_all_devices, fn -> false end)
      |> assign_new(:show_clear_inactive_modal, fn -> false end)
      |> load_config()
      |> load_devices()
      |> load_p2p_status()

    # Subscribe to claim expiry notifications on first mount
    if connected?(socket) and is_nil(assigns[:subscribed]) do
      Phoenix.PubSub.subscribe(Mydia.PubSub, "remote_access:claims")
    end

    {:ok, assign(socket, :subscribed, true)}
  end

  @impl true
  def render(assigns) do
    # Check if P2P is running
    p2p_running =
      assigns.ra_config && assigns.ra_config.enabled && assigns.p2p_status &&
        assigns.p2p_status.running

    # Get local address info
    local_addr = get_local_address()

    # Get auto-detected URLs (public + local)
    detected_urls = get_detected_urls()

    assigns =
      assigns
      |> assign(:p2p_running, p2p_running)
      |> assign(:local_addr, local_addr)
      |> assign(:detected_urls, detected_urls)

    ~H"""
    <div class="p-4 sm:p-6 space-y-5">
      <%!-- Header --%>
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-3">
          <div class={[
            "w-10 h-10 rounded-xl flex items-center justify-center transition-colors",
            if(@ra_config && @ra_config.enabled && @p2p_running,
              do: "bg-success/15",
              else: "bg-base-300"
            )
          ]}>
            <.icon
              name="hero-signal"
              class={"w-5 h-5 #{if @ra_config && @ra_config.enabled && @p2p_running, do: "text-success", else: "opacity-50"}"}
            />
          </div>
          <div>
            <h2 class="font-semibold">Remote Access</h2>
            <p class="text-xs text-base-content/50">
              <%= cond do %>
                <% !(@ra_config && @ra_config.enabled) -> %>
                  Connect from anywhere
                <% @p2p_running -> %>
                  P2P mesh active
                <% true -> %>
                  Initializing...
              <% end %>
            </p>
          </div>
        </div>
        <input
          type="checkbox"
          id="remote-access-toggle"
          class="toggle toggle-success"
          checked={@ra_config && @ra_config.enabled}
          phx-click="toggle_remote_access"
          phx-target={@myself}
          phx-value-enabled={to_string(!(@ra_config && @ra_config.enabled))}
        />
      </div>

      <%= if @ra_config && @ra_config.enabled do %>
        <%!-- Pairing & Status Row --%>
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <%!-- Pair New Device Card --%>
          <%= if @p2p_running do %>
            <div
              class="group flex items-center gap-3 p-4 bg-gradient-to-br from-primary/5 via-base-200 to-secondary/5 rounded-xl border border-primary/20 cursor-pointer hover:border-primary/40 hover:shadow-lg hover:shadow-primary/5 transition-all"
              phx-click="open_pairing_modal"
              phx-target={@myself}
            >
              <div class="w-11 h-11 rounded-xl bg-gradient-to-br from-primary to-secondary flex items-center justify-center shadow-md group-hover:scale-105 transition-transform">
                <.icon name="hero-qr-code" class="w-5 h-5 text-primary-content" />
              </div>
              <div class="flex-1">
                <div class="font-semibold group-hover:text-primary transition-colors">
                  Pair New Device
                </div>
                <div class="text-xs text-base-content/50">
                  Scan QR or enter code
                </div>
              </div>
              <.icon
                name="hero-chevron-right"
                class="w-5 h-5 text-base-content/30 group-hover:text-primary group-hover:translate-x-0.5 transition-all"
              />
            </div>
          <% else %>
            <div class="flex items-center gap-3 p-4 bg-base-200 rounded-xl border border-base-300 opacity-60">
              <div class="w-11 h-11 rounded-xl bg-base-300 flex items-center justify-center">
                <span class="loading loading-spinner loading-sm"></span>
              </div>
              <div class="flex-1">
                <div class="font-semibold">Pair New Device</div>
                <div class="text-xs text-base-content/50">Starting...</div>
              </div>
            </div>
          <% end %>

          <%!-- Status Card --%>
          <div class="flex flex-col gap-2 p-4 bg-base-200 rounded-xl border border-base-300">
            <div class="flex items-center gap-3">
              <div class={[
                "w-3 h-3 rounded-full shrink-0",
                if(@p2p_running, do: "bg-success", else: "bg-warning animate-pulse")
              ]}>
              </div>
              <div class="min-w-0 flex-1">
                <div class="font-medium text-sm">
                  {if @p2p_running, do: "P2P Online", else: "P2P Starting..."}
                </div>
                <div class="text-xs text-base-content/50">
                  <%= if @p2p_status && @p2p_status.relay_connected do %>
                    <span class="text-success">Relay connected</span>
                  <% else %>
                    <span class="text-warning">Relay disconnected</span>
                  <% end %>
                  <%= if @p2p_status && @p2p_status.connected_peers > 0 do %>
                    <span class="mx-1">·</span>
                    <span>
                      {@p2p_status.connected_peers} device{if @p2p_status.connected_peers == 1,
                        do: "",
                        else: "s"} online
                    </span>
                  <% end %>
                </div>
              </div>

              <%!-- Node ID (subtle) --%>
              <%= if @p2p_status && @p2p_status.node_id do %>
                <button
                  class="hidden lg:flex items-center gap-1.5 text-xs text-base-content/40 hover:text-base-content/60 transition-colors"
                  phx-click="copy_peer_id"
                  phx-target={@myself}
                  onclick={"navigator.clipboard.writeText('#{@p2p_status.node_id}')"}
                  title={"Copy Node ID: #{@p2p_status.node_id}"}
                >
                  <code class="font-mono">{String.slice(@p2p_status.node_id, 0..7)}</code>
                  <.icon name="hero-clipboard-document" class="w-3 h-3" />
                </button>
              <% end %>

              <button
                class="btn btn-ghost btn-xs btn-square opacity-50 hover:opacity-100 shrink-0"
                phx-click="refresh_p2p"
                phx-target={@myself}
                title="Refresh"
              >
                <.icon name="hero-arrow-path" class="w-3.5 h-3.5" />
              </button>
            </div>
          </div>
        </div>

        <%!-- Powered by Iroh --%>
        <div class="flex justify-center -mt-1">
          <a
            href="https://www.iroh.computer/"
            target="_blank"
            rel="noopener noreferrer"
            class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full bg-base-200 hover:bg-purple-500/10 border border-base-300 hover:border-purple-500/20 text-xs text-base-content/40 hover:text-purple-500 transition-all"
          >
            <span>Powered by</span>
            <svg viewBox="0 0 93.26 32" aria-hidden="true" class="h-3 fill-purple-500">
              <path d="M61.21,9.93h-7.74c-3.25,0-5.89,2.64-5.89,5.89v8.27c0,3.25,2.64,5.89,5.89,5.89h7.74c3.25,0,5.89-2.64,5.89-5.89V15.81c0-3.25-2.64-5.89-5.89-5.89Zm2.93,14.79c0,.29-.11,.57-.32,.77l-1.21,1.21c-.2,.2-.49,.32-.77,.32h-8.99c-.29,0-.57-.11-.77-.32l-1.21-1.21c-.21-.21-.32-.48-.32-.77V15.18c0-.29,.11-.57,.32-.77l1.21-1.21c.21-.21,.48-.32,.77-.32h8.99c.29,0,.57,.12,.77,.32l1.21,1.21c.21,.21,.32,.48,.32,.77v9.53Z">
              </path>
              <path d="M90.26,14.29c-.29-1.14-.73-2.04-1.32-2.69-.59-.66-1.35-1.11-2.28-1.38-.93-.26-2.03-.39-3.28-.39-1.6,0-2.94,.26-4.01,.77-1.08,.51-1.94,1.33-2.83,2.14h-.2V3.03c0-.33-.27-.6-.6-.6h-4.46v2.64h2.03V29.97h3.03v-13.25h0v-.18c0-.29,.11-.57,.32-.77,0,0,2.49-2.45,3.83-2.93,.68-.24,1.37-.37,2.08-.37,1.02,0,1.86,.14,2.51,.43,.65,.29,1.17,.71,1.55,1.28,.38,.56,.63,1.27,.76,2.1,.13,.84,.2,1.82,.2,2.95v10.74h3.11v-11.33c0-1.76-.14-3.21-.43-4.35Z">
              </path>
              <g>
                <path d="M1.71,29.97v-2.64H9.87V12.94H1.71v-2.64H12.98V27.34h8.21v2.64H1.71Z"></path>
                <circle cx="11.41" cy="4.65" r="2.44"></circle>
              </g>
              <path d="M42.74,14.29c-.11-.93-.31-1.72-.61-2.38-.3-.66-.72-1.15-1.26-1.49-.54-.34-1.25-.51-2.14-.51-1.52,0-2.83,.29-3.93,.87-1.1,.58-2.1,1.27-2.99,2.08h-.2l-.55-2.22c-.05-.2-.23-.34-.43-.34h-7.01v2.64h5.31v14.4h-5.31v2.64h15.89v-2.64h-7.55v-10.63s0-.02,0-.03v-.45c0-.29,.11-.57,.32-.77,0,0,1.87-1.96,3.38-2.47,.66-.22,1.39-.3,2.2-.3,.87,0,1.46,.39,1.79,1.17,.33,.78,.49,2,.49,3.67l2.75-.04c0-1.18-.05-2.24-.16-3.17Z">
              </path>
            </svg>
          </a>
        </div>

        <%!-- Devices Section --%>
        <% device_count = length(@devices)
        visible_devices = if @show_all_devices, do: @devices, else: Enum.take(@devices, 10)
        hidden_count = device_count - length(visible_devices)

        inactive_devices =
          Enum.reject(@devices, fn d ->
            is_recent_activity?(d.last_seen_at) && is_nil(d.revoked_at)
          end)

        inactive_count = length(inactive_devices) %>
        <div class="space-y-4">
          <div class="flex items-center justify-between">
            <h3 class="text-sm font-medium text-base-content/70 flex items-center gap-2">
              <.icon name="hero-device-phone-mobile" class="w-4 h-4" /> Paired Devices
              <span class="badge badge-ghost badge-sm">{device_count}</span>
            </h3>
            <%= if inactive_count > 0 do %>
              <button
                class="btn btn-ghost btn-xs text-base-content/60"
                phx-click="open_clear_inactive_modal"
                phx-target={@myself}
              >
                <.icon name="hero-trash" class="w-3 h-3" /> Clear inactive ({inactive_count})
              </button>
            <% end %>
          </div>

          <%= if @devices == [] do %>
            <div class="card bg-base-200">
              <div class="card-body items-center text-center py-8">
                <div class="w-16 h-16 rounded-full bg-base-300 flex items-center justify-center mb-2">
                  <.icon name="hero-device-phone-mobile" class="w-8 h-8 opacity-40" />
                </div>
                <h4 class="font-medium text-base-content/70">No Devices Paired</h4>
                <p class="text-sm text-base-content/50 max-w-xs">
                  Generate a pairing code above to connect your first device.
                </p>
              </div>
            </div>
          <% else %>
            <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-2">
              <%= for device <- visible_devices do %>
                <div class={[
                  "group card bg-base-200 transition-all duration-200",
                  if(RemoteAccess.RemoteDevice.revoked?(device),
                    do: "opacity-60",
                    else: "hover:bg-base-300/50"
                  )
                ]}>
                  <div class="card-body p-3">
                    <div class="flex items-center gap-3">
                      <%!-- Device Icon --%>
                      <div class={[
                        "w-9 h-9 rounded-lg flex items-center justify-center shrink-0",
                        cond do
                          RemoteAccess.RemoteDevice.revoked?(device) -> "bg-error/10 text-error"
                          is_recent_activity?(device.last_seen_at) -> "bg-success/10 text-success"
                          true -> "bg-base-300 text-base-content/50"
                        end
                      ]}>
                        <.icon name={platform_icon(device.platform)} class="w-5 h-5" />
                      </div>

                      <%!-- Device Info --%>
                      <div class="flex-1 min-w-0">
                        <div class="flex items-center gap-1.5">
                          <span class="font-medium text-sm truncate">{device.device_name}</span>
                          <%= if RemoteAccess.RemoteDevice.revoked?(device) do %>
                            <span class="badge badge-error badge-xs">Revoked</span>
                          <% else %>
                            <%= if is_recent_activity?(device.last_seen_at) do %>
                              <span class="w-1.5 h-1.5 rounded-full bg-success animate-pulse shrink-0">
                              </span>
                            <% end %>
                          <% end %>
                        </div>
                        <div class="text-xs text-base-content/50 truncate">
                          <%= cond do %>
                            <% RemoteAccess.RemoteDevice.revoked?(device) -> %>
                              Access revoked
                            <% is_recent_activity?(device.last_seen_at) -> %>
                              Online now
                            <% is_nil(device.last_seen_at) -> %>
                              Never connected
                            <% true -> %>
                              {format_relative_time(device.last_seen_at)}
                          <% end %>
                        </div>
                      </div>

                      <%!-- Actions dropdown --%>
                      <div class="dropdown dropdown-end">
                        <div
                          tabindex="0"
                          role="button"
                          class="btn btn-ghost btn-xs btn-square opacity-50 group-hover:opacity-100"
                        >
                          <.icon name="hero-ellipsis-vertical" class="w-4 h-4" />
                        </div>
                        <ul
                          tabindex="0"
                          class="dropdown-content menu bg-base-100 rounded-box z-10 w-40 p-1 shadow-lg border border-base-300"
                        >
                          <%= if is_nil(device.revoked_at) do %>
                            <li>
                              <button
                                class="text-warning"
                                phx-click="open_revoke_modal"
                                phx-target={@myself}
                                phx-value-id={device.id}
                              >
                                <.icon name="hero-no-symbol" class="w-4 h-4" /> Revoke
                              </button>
                            </li>
                          <% end %>
                          <li>
                            <button
                              class="text-error"
                              phx-click="open_delete_modal"
                              phx-target={@myself}
                              phx-value-id={device.id}
                            >
                              <.icon name="hero-trash" class="w-4 h-4" /> Remove
                            </button>
                          </li>
                        </ul>
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
            <%= if hidden_count > 0 do %>
              <button
                class="btn btn-ghost btn-sm w-full gap-2"
                phx-click="toggle_show_all_devices"
                phx-target={@myself}
              >
                <.icon name="hero-chevron-down" class="w-4 h-4" />
                Show {hidden_count} more device{if hidden_count == 1, do: "", else: "s"}
              </button>
            <% end %>
            <%= if @show_all_devices && device_count > 10 do %>
              <button
                class="btn btn-ghost btn-sm w-full gap-2"
                phx-click="toggle_show_all_devices"
                phx-target={@myself}
              >
                <.icon name="hero-chevron-up" class="w-4 h-4" /> Show less
              </button>
            <% end %>
          <% end %>
        </div>

        <%!-- Direct URLs Card --%>
        <div class="card bg-base-200">
          <div class="card-body p-4 gap-3">
            <div class="flex items-center justify-between">
              <h4 class="card-title text-sm gap-2">
                <.icon name="hero-link" class="w-4 h-4 opacity-60" /> Direct URLs
              </h4>
              <button
                class="btn btn-sm btn-ghost gap-1"
                phx-click="open_add_url_modal"
                phx-target={@myself}
              >
                <.icon name="hero-plus" class="w-4 h-4" /> Add URL
              </button>
            </div>

            <p class="text-xs text-base-content/60 -mt-1">
              Direct URLs allow the app to bypass the relay when on the same network for faster streaming.
            </p>

            <div class="grid gap-4 sm:grid-cols-2 mt-1">
              <%!-- Manual URLs Section --%>
              <div class="space-y-2">
                <div class="flex items-center gap-2">
                  <.icon name="hero-pencil-square" class="w-3.5 h-3.5 opacity-50" />
                  <span class="text-xs font-medium text-base-content/70">Manual URLs</span>
                  <%= if @ra_config.direct_urls && @ra_config.direct_urls != [] do %>
                    <span class="badge badge-ghost badge-xs">{length(@ra_config.direct_urls)}</span>
                  <% end %>
                </div>

                <%= if @ra_config.direct_urls && @ra_config.direct_urls != [] do %>
                  <div class="space-y-1.5">
                    <%= for url <- @ra_config.direct_urls do %>
                      <div class="flex items-center gap-2 bg-base-300/50 rounded-lg px-3 py-2 group">
                        <.icon name="hero-link" class="w-3.5 h-3.5 opacity-40 shrink-0" />
                        <code class="font-mono text-xs truncate flex-1">{url}</code>
                        <button
                          class="btn btn-xs btn-ghost btn-square opacity-50 group-hover:opacity-100 hover:btn-error"
                          phx-click="remove_direct_url"
                          phx-target={@myself}
                          phx-value-url={url}
                          title="Remove URL"
                        >
                          <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
                        </button>
                      </div>
                    <% end %>
                  </div>
                <% else %>
                  <div class="flex items-center gap-2 text-xs text-base-content/50 italic bg-base-300/30 rounded-lg px-3 py-3">
                    <.icon name="hero-plus-circle" class="w-4 h-4 opacity-40" />
                    <span>Click "Add URL" to add custom addresses</span>
                  </div>
                <% end %>
              </div>

              <%!-- Auto-detected URLs Section --%>
              <div class="space-y-2">
                <div class="flex items-center gap-2">
                  <.icon name="hero-signal" class="w-3.5 h-3.5 opacity-50" />
                  <span class="text-xs font-medium text-base-content/70">Auto-detected</span>
                  <%= if @detected_urls != [] do %>
                    <span class="badge badge-ghost badge-xs">{length(@detected_urls)}</span>
                  <% end %>
                </div>

                <%= if @detected_urls != [] do %>
                  <div class="space-y-1.5">
                    <%= for url <- @detected_urls do %>
                      <div class="flex items-center gap-2 bg-base-300/30 rounded-lg px-3 py-2 border border-dashed border-base-300">
                        <.icon name="hero-signal" class="w-3.5 h-3.5 opacity-40 shrink-0" />
                        <code class="font-mono text-xs truncate flex-1 text-base-content/70">
                          {url}
                        </code>
                        <span class="badge badge-xs badge-ghost">Auto</span>
                      </div>
                    <% end %>
                  </div>
                <% else %>
                  <div class="flex items-center gap-2 text-xs text-base-content/50 italic bg-base-300/30 rounded-lg px-3 py-3">
                    <.icon name="hero-exclamation-circle" class="w-4 h-4 opacity-40" />
                    <span>No URLs detected. Check network config.</span>
                  </div>
                <% end %>
              </div>
            </div>

            <div class="divider my-1"></div>

            <div class="alert bg-info/10 border-info/20 py-2.5">
              <.icon name="hero-light-bulb" class="w-5 h-5 text-info" />
              <div class="text-xs">
                <span class="font-semibold">Tip:</span>
                Use
                <a
                  href="https://tailscale.com"
                  target="_blank"
                  rel="noopener"
                  class="link link-info font-medium"
                >
                  Tailscale
                </a>
                for secure access anywhere. Add your Tailscale address, e.g.
                <code class="bg-info/20 px-1.5 py-0.5 rounded font-mono text-info">
                  http://mydia.tail1234.ts.net:4000
                </code>
              </div>
            </div>
          </div>
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

      <%!-- Clear Inactive Devices Modal --%>
      <%= if @show_clear_inactive_modal do %>
        <% inactive_to_clear =
          Enum.reject(@devices, fn d ->
            is_recent_activity?(d.last_seen_at) && is_nil(d.revoked_at)
          end) %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg mb-4">Clear Inactive Devices?</h3>
            <p class="text-base-content/70 mb-3">
              This will remove <strong>{length(inactive_to_clear)}</strong>
              inactive device{if length(inactive_to_clear) == 1, do: "", else: "s"}.
              They will need to be paired again to reconnect.
            </p>
            <div class="text-sm text-base-content/50 max-h-32 overflow-y-auto">
              <%= for device <- inactive_to_clear do %>
                <div class="flex items-center gap-2 py-1">
                  <.icon name={platform_icon(device.platform)} class="w-3 h-3 opacity-60" />
                  <span class="truncate">{device.device_name}</span>
                </div>
              <% end %>
            </div>
            <div class="modal-action">
              <button
                phx-click="close_clear_inactive_modal"
                phx-target={@myself}
                class="btn btn-ghost"
              >
                Cancel
              </button>
              <button phx-click="submit_clear_inactive" phx-target={@myself} class="btn btn-error">
                Clear All
              </button>
            </div>
          </div>
          <div
            class="modal-backdrop"
            phx-click="close_clear_inactive_modal"
            phx-target={@myself}
          >
          </div>
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
            <.form
              for={%{}}
              as={:direct_url}
              id="add-direct-url-form"
              phx-change="update_new_url"
              phx-submit="add_direct_url"
              phx-target={@myself}
            >
              <input
                type="url"
                name="url"
                placeholder="https://mydia.local:4000"
                class="input input-bordered w-full"
                value={@new_url}
              />
              <div class="modal-action">
                <button
                  type="button"
                  phx-click="close_add_url_modal"
                  phx-target={@myself}
                  class="btn btn-ghost"
                >
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary" disabled={@new_url == ""}>
                  Add
                </button>
              </div>
            </.form>
          </div>
          <div class="modal-backdrop" phx-click="close_add_url_modal" phx-target={@myself}></div>
        </div>
      <% end %>

      <%!-- Pair New Device Modal --%>
      <%= if @show_pairing_modal do %>
        <div class="modal modal-open">
          <div class="modal-box max-w-md shadow-2xl">
            <%!-- Header --%>
            <div class="flex items-center justify-between mb-2">
              <div class="flex items-center gap-3">
                <div class="w-10 h-10 rounded-xl bg-primary/10 flex items-center justify-center">
                  <.icon name="hero-device-phone-mobile" class="w-5 h-5 text-primary" />
                </div>
                <div>
                  <h3 class="text-lg font-semibold">Pair New Device</h3>
                  <p class="text-sm text-base-content/50">Open the Mydia app to connect</p>
                </div>
              </div>
              <button
                class="btn btn-sm btn-circle btn-ghost"
                phx-click="close_pairing_modal"
                phx-target={@myself}
              >
                <.icon name="hero-x-mark" class="w-5 h-5" />
              </button>
            </div>

            <%= if @claim_code do %>
              <%!-- Active pairing code --%>
              <div class="space-y-5 pt-4">
                <%!-- QR Code - only show when registered on rendezvous --%>
                <%= if @claim_code_rendezvous_status == :registered do %>
                  <% qr_svg = generate_qr_code(@ra_config, @p2p_status, @claim_code) %>
                  <%= if qr_svg do %>
                    <div class="flex flex-col items-center gap-2">
                      <div class="p-3 bg-white rounded-xl shadow-md">
                        {Phoenix.HTML.raw(qr_svg)}
                      </div>
                      <div class="flex flex-col items-center gap-1">
                        <span class="text-xs text-base-content/40">QR Contents</span>
                        <div class="flex flex-wrap justify-center gap-1.5">
                          <div class="tooltip" data-tip="Instance ID">
                            <span class="badge badge-sm badge-ghost gap-1 font-mono">
                              <.icon name="hero-server" class="w-3 h-3 opacity-50" />
                              {String.slice(@ra_config.instance_id, 0..7)}
                            </span>
                          </div>
                          <%= if @p2p_status && @p2p_status.node_id do %>
                            <div class="tooltip" data-tip="Node ID (for P2P discovery)">
                              <span class="badge badge-sm badge-ghost gap-1 font-mono">
                                <.icon name="hero-signal" class="w-3 h-3 opacity-50" />
                                {String.slice(@p2p_status.node_id, 0..7)}
                              </span>
                            </div>
                          <% end %>
                          <div class="tooltip" data-tip="Claim Code (see below)">
                            <span class="badge badge-sm badge-ghost gap-1">
                              <.icon name="hero-ticket" class="w-3 h-3 opacity-50" /> Claim Code
                            </span>
                          </div>
                        </div>
                      </div>
                    </div>
                  <% end %>
                <% end %>

                <%!-- Divider - only show when registered --%>
                <%= if @claim_code_rendezvous_status == :registered do %>
                  <div class="flex items-center gap-3">
                    <div class="flex-1 h-px bg-base-300"></div>
                    <span class="text-xs text-base-content/40 uppercase tracking-wider">
                      or enter code
                    </span>
                    <div class="flex-1 h-px bg-base-300"></div>
                  </div>
                <% end %>

                <%!-- Pairing Code --%>
                <div class="text-center">
                  <%= if @claim_code_rendezvous_status == :registered do %>
                    <%!-- Code is registered and ready to use --%>
                    <div class="inline-flex items-center gap-2 bg-base-200 rounded-xl px-5 py-3">
                      <code class="text-2xl font-bold tracking-[0.25em] font-mono">
                        {@claim_code}
                      </code>
                      <button
                        class="btn btn-ghost btn-sm btn-square"
                        phx-click="copy_claim_code"
                        phx-target={@myself}
                        onclick={"navigator.clipboard.writeText('#{@claim_code}')"}
                        title="Copy code"
                      >
                        <.icon name="hero-clipboard-document" class="w-4 h-4 opacity-50" />
                      </button>
                    </div>
                    <div class="mt-2 flex items-center justify-center gap-1.5 text-xs">
                      <.icon name="hero-check-circle" class="w-4 h-4 text-success" />
                      <span class="text-success">Ready for pairing</span>
                    </div>
                  <% else %>
                    <%!-- Code is being registered - show loading state --%>
                    <div class="inline-flex flex-col items-center gap-3 bg-base-200 rounded-xl px-8 py-5">
                      <span class="loading loading-spinner loading-lg text-primary"></span>
                      <div class="text-sm text-base-content/60">
                        <%= case @claim_code_rendezvous_status do %>
                          <% :pending -> %>
                            Registering pairing code...
                          <% {:error, _reason} -> %>
                            <span class="text-warning">Registration failed, retrying...</span>
                          <% _ -> %>
                            Preparing pairing code...
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                </div>

                <%!-- Countdown & Regenerate --%>
                <div class="flex items-center justify-center gap-4">
                  <div class="flex items-center gap-3">
                    <div
                      class={[
                        "radial-progress text-xs",
                        if(@countdown_seconds > 60, do: "text-success", else: "text-warning")
                      ]}
                      style={"--value:#{min(100, @countdown_seconds / 3)}; --size:2.5rem; --thickness:3px;"}
                      role="progressbar"
                    >
                      <.icon name="hero-clock" class="w-4 h-4" />
                    </div>
                    <div class="text-sm">
                      <span class="text-base-content/60">Expires in</span>
                      <span class={[
                        "font-mono font-semibold ml-1",
                        if(@countdown_seconds > 60, do: "text-base-content", else: "text-warning")
                      ]}>
                        {format_countdown(@countdown_seconds)}
                      </span>
                    </div>
                  </div>
                  <span class="text-base-content/20">•</span>
                  <button
                    id="regenerate-pairing-code-btn"
                    class="link link-hover text-sm text-base-content/60"
                    phx-click="generate_claim_code"
                    phx-target={@myself}
                    phx-disable-with="..."
                  >
                    New Code
                  </button>
                </div>
              </div>
            <% else %>
              <%!-- Error or loading state --%>
              <div class="text-center py-8 space-y-4">
                <%= if @pairing_error do %>
                  <div class="alert alert-error text-left text-sm">
                    <.icon name="hero-exclamation-circle" class="w-4 h-4" />
                    <span>{@pairing_error}</span>
                  </div>
                <% end %>

                <div class="flex justify-center">
                  <span class="loading loading-spinner loading-lg text-primary/50"></span>
                </div>
                <p class="text-sm text-base-content/50">Generating pairing code...</p>
              </div>
            <% end %>
          </div>
          <div
            class="modal-backdrop bg-base-300/60 backdrop-blur-sm"
            phx-click="close_pairing_modal"
            phx-target={@myself}
          >
          </div>
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
         :ok <- maybe_start_or_stop_p2p(enabled) do
      {:noreply,
       socket
       |> assign(:ra_config, updated_config)
       |> load_p2p_status()
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
         |> load_p2p_status()
         |> put_flash(:error, "Failed to start P2P: remote access not fully configured")}

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

  def handle_event("copy_peer_id", _params, socket) do
    {:noreply, put_flash(socket, :info, "Node ID copied to clipboard")}
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

  def handle_event("open_clear_inactive_modal", _params, socket) do
    {:noreply, assign(socket, :show_clear_inactive_modal, true)}
  end

  def handle_event("close_clear_inactive_modal", _params, socket) do
    {:noreply, assign(socket, :show_clear_inactive_modal, false)}
  end

  def handle_event("submit_clear_inactive", _params, socket) do
    devices = socket.assigns.devices

    # Find inactive devices (not recently active or revoked)
    inactive_devices =
      Enum.reject(devices, fn d ->
        is_recent_activity?(d.last_seen_at) && is_nil(d.revoked_at)
      end)

    # Delete all inactive devices
    deleted_count =
      Enum.reduce(inactive_devices, 0, fn device, count ->
        case RemoteAccess.delete_device(device) do
          {:ok, _} -> count + 1
          {:error, _} -> count
        end
      end)

    {:noreply,
     socket
     |> assign(:show_clear_inactive_modal, false)
     |> put_flash(
       :info,
       "Removed #{deleted_count} inactive device#{if deleted_count == 1, do: "", else: "s"}."
     )
     |> load_devices()}
  end

  def handle_event("open_pairing_modal", _params, socket) do
    # Open modal and immediately generate a code if we don't have one
    socket = assign(socket, :show_pairing_modal, true)

    socket =
      if is_nil(socket.assigns.claim_code) do
        do_generate_claim_code(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("close_pairing_modal", _params, socket) do
    {:noreply, assign(socket, :show_pairing_modal, false)}
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

  def handle_event("update_new_url", %{"url" => value}, socket) do
    {:noreply, assign(socket, :new_url, value)}
  end

  def handle_event("update_new_url", %{"direct_url" => %{"url" => value}}, socket) do
    {:noreply, assign(socket, :new_url, value)}
  end

  def handle_event("add_direct_url", _params, socket) do
    config = socket.assigns.ra_config
    new_url = String.trim(socket.assigns.new_url)

    if new_url != "" do
      current_urls = config.direct_urls || []
      updated_urls = Enum.uniq(current_urls ++ [new_url])

      # Legacy relay URL update - now a no-op, URLs stored locally only
      {:ok, _urls} = RemoteAccess.update_relay_urls(updated_urls)

      {:noreply,
       socket
       |> assign(:show_add_url_modal, false)
       |> assign(:new_url, "")
       |> load_config()
       |> put_flash(:info, "Direct URL added successfully")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_direct_url", %{"url" => url}, socket) do
    config = socket.assigns.ra_config
    current_urls = config.direct_urls || []
    updated_urls = Enum.reject(current_urls, &(&1 == url))

    {:ok, _urls} = RemoteAccess.update_relay_urls(updated_urls)

    {:noreply,
     socket
     |> load_config()
     |> put_flash(:info, "Direct URL removed successfully")}
  end

  def handle_event("refresh_p2p", _params, socket) do
    {:noreply,
     socket
     |> load_p2p_status()
     |> put_flash(:info, "Status refreshed")}
  end

  def handle_event("toggle_advanced", _params, socket) do
    {:noreply, assign(socket, :show_advanced, !socket.assigns.show_advanced)}
  end

  def handle_event("toggle_show_all_devices", _params, socket) do
    {:noreply, assign(socket, :show_all_devices, !socket.assigns.show_all_devices)}
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
    p2p_status = socket.assigns.p2p_status

    Logger.debug("Generating pairing code for user #{user_id}, p2p_status=#{inspect(p2p_status)}")

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
        |> assign(:claim_code_rendezvous_status, :registered)
        |> assign(:claim_expires_at, expires_at)
        |> assign(:countdown_seconds, max(0, seconds))

      {:error, :p2p_not_running} ->
        Logger.warning("Failed to generate pairing code: P2P service not running")

        assign(
          socket,
          :pairing_error,
          "P2P service is not running. Please try again."
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

  # P2P is started automatically by the application supervision tree
  # These are effectively no-ops now but kept for API compatibility
  defp maybe_start_or_stop_p2p(true), do: RemoteAccess.start_relay()
  defp maybe_start_or_stop_p2p(false), do: RemoteAccess.stop_relay()

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

  defp load_p2p_status(socket) do
    {:ok, p2p_status} = RemoteAccess.p2p_status()
    assign(socket, :p2p_status, p2p_status)
  end

  defp format_countdown(seconds) when seconds <= 0, do: "Expired"

  defp format_countdown(seconds) do
    minutes = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{minutes}:#{String.pad_leading(Integer.to_string(secs), 2, "0")}"
  end

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %Y at %I:%M %p")
  end

  # Consider a device "active" (online now) if seen within the last 10 minutes.
  # This matches the touch throttle of 5 minutes, plus buffer for network delays.
  @active_threshold_seconds 600

  defp is_recent_activity?(nil), do: false

  defp is_recent_activity?(last_seen) do
    threshold = DateTime.utc_now() |> DateTime.add(-@active_threshold_seconds, :second)
    DateTime.compare(last_seen, threshold) == :gt
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
      diff_seconds < 86400 -> "#{pluralize(div(diff_seconds, 3600), "hour")} ago"
      diff_seconds < 604_800 -> "#{pluralize(div(diff_seconds, 86400), "day")} ago"
      true -> format_datetime(dt)
    end
  end

  defp pluralize(1, word), do: "1 #{word}"
  defp pluralize(n, word), do: "#{n} #{word}s"

  # Normalize claim code by removing whitespace and dashes, converting to uppercase
  defp normalize_code(code) when is_binary(code) do
    code
    |> String.replace(~r/[\s-]/, "")
    |> String.upcase()
  end

  defp normalize_code(nil), do: nil

  defp generate_qr_code(config, p2p_status, claim_code) do
    if config && claim_code do
      # Build QR code content for P2P-based pairing
      # The client will use node_addr for direct dialing and claim_code for validation
      content =
        Jason.encode!(%{
          instance_id: config.instance_id,
          node_addr: p2p_status && p2p_status.node_addr,
          claim_code: claim_code
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

  defp get_detected_urls do
    # Get auto-detected URLs (public IP + local network)
    public_urls = Mydia.RemoteAccess.DirectUrls.detect_public_urls()
    local_urls = Mydia.RemoteAccess.DirectUrls.detect_local_urls()

    # Combine and deduplicate
    (public_urls ++ local_urls)
    |> Enum.uniq()
  end

  defp valid_local_ip?({127, _, _, _}), do: false
  defp valid_local_ip?({169, 254, _, _}), do: false
  defp valid_local_ip?({172, 17, _, _}), do: false

  defp valid_local_ip?({a, b, c, d})
       when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) and
              tuple_size({a, b, c, d}) == 4,
       do: true

  defp valid_local_ip?(_), do: false
end
