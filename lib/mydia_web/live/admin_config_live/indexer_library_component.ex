defmodule MydiaWeb.AdminConfigLive.IndexerLibraryComponent do
  @moduledoc """
  LiveComponent for managing the indexer library.

  This component provides a modal interface for browsing, searching, and enabling
  indexers from the built-in indexer definition library.
  """
  use MydiaWeb, :live_component

  alias Mydia.Indexers
  alias Mydia.Indexers.CardigannDefinition

  require Logger
  alias Mydia.Logger, as: MydiaLogger

  @impl true
  def update(%{sync_result: result} = _assigns, socket) do
    # Handle sync completion result from parent LiveView
    socket =
      case result do
        {:ok, stats} ->
          socket
          |> assign(:syncing, false)
          |> put_flash(
            :info,
            "Sync completed: #{stats.created} created, #{stats.updated} updated, #{stats.failed} failed"
          )
          |> load_indexers()

        {:error, reason} ->
          Logger.error("[IndexerLibrary] Sync failed: #{inspect(reason)}")

          socket
          |> assign(:syncing, false)
          |> put_flash(:error, "Sync failed: #{format_sync_error(reason)}")
      end

    {:ok, socket}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:filter_type, fn -> "all" end)
      |> assign_new(:filter_language, fn -> "all" end)
      |> assign_new(:filter_enabled, fn -> "all" end)
      |> assign_new(:search_query, fn -> "" end)
      |> assign_new(:syncing, fn -> false end)
      |> assign_new(:configuring_definition, fn -> nil end)
      |> assign_new(:config_form, fn -> nil end)
      |> load_indexers()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="modal modal-open">
        <div class="modal-box max-w-5xl max-h-[90vh]">
          <%!-- Header with Close Button --%>
          <div class="flex items-center justify-between mb-4">
            <div>
              <h3 class="font-bold text-lg flex items-center gap-2">
                <.icon name="hero-book-open" class="w-5 h-5 opacity-60" /> Indexer Library
              </h3>
              <p class="text-base-content/70 text-sm mt-1">
                Browse and enable indexers from the definition library
              </p>
            </div>
            <button
              class="btn btn-sm btn-ghost btn-circle"
              phx-click="close_indexer_library"
              title="Close"
            >
              <.icon name="hero-x-mark" class="w-5 h-5" />
            </button>
          </div>
          <%!-- Experimental Warning --%>
          <div class="alert alert-warning mb-4">
            <.icon name="hero-beaker" class="w-5 h-5" />
            <span class="text-sm">
              <span class="font-medium">Experimental:</span>
              Only a limited number of indexers have been tested. Prowlarr and Jackett integrations are stable and recommended.
            </span>
          </div>
          <%!-- Filters and Search --%>
          <div class="card bg-base-200 shadow-sm mb-4">
            <div class="card-body p-4">
              <div class="flex flex-wrap gap-4 items-end">
                <%!-- Search --%>
                <div class="form-control flex-1 min-w-48">
                  <label class="label py-1">
                    <span class="label-text text-xs">Search</span>
                  </label>
                  <form id="indexer-library-search-form" phx-change="search" phx-target={@myself}>
                    <input
                      type="text"
                      name="search[query]"
                      value={@search_query}
                      placeholder="Search by name or description..."
                      class="input input-bordered input-sm w-full"
                    />
                  </form>
                </div>
                <%!-- Filter Dropdowns --%>
                <.form
                  for={%{}}
                  id="indexer-library-filter-form"
                  phx-change="filter"
                  phx-target={@myself}
                  class="contents"
                >
                  <%!-- Type Filter --%>
                  <div class="form-control">
                    <label class="label py-1">
                      <span class="label-text text-xs">Type</span>
                    </label>
                    <select class="select select-bordered select-sm" name="type">
                      <option value="all" selected={@filter_type == "all"}>All Types</option>
                      <option value="public" selected={@filter_type == "public"}>Public</option>
                      <option value="private" selected={@filter_type == "private"}>Private</option>
                      <option value="semi-private" selected={@filter_type == "semi-private"}>
                        Semi-Private
                      </option>
                    </select>
                  </div>
                  <%!-- Language Filter --%>
                  <div class="form-control">
                    <label class="label py-1">
                      <span class="label-text text-xs">Language</span>
                    </label>
                    <select class="select select-bordered select-sm" name="language">
                      <option value="all" selected={@filter_language == "all"}>All Languages</option>
                      <%= for language <- @available_languages do %>
                        <option value={language} selected={@filter_language == language}>
                          {language}
                        </option>
                      <% end %>
                    </select>
                  </div>
                  <%!-- Status Filter --%>
                  <div class="form-control">
                    <label class="label py-1">
                      <span class="label-text text-xs">Status</span>
                    </label>
                    <select class="select select-bordered select-sm" name="enabled">
                      <option value="all" selected={@filter_enabled == "all"}>All Status</option>
                      <option value="enabled" selected={@filter_enabled == "enabled"}>Enabled</option>
                      <option value="disabled" selected={@filter_enabled == "disabled"}>
                        Disabled
                      </option>
                    </select>
                  </div>
                </.form>
                <%!-- Sync Button --%>
                <div class="form-control">
                  <button
                    class={["btn btn-primary btn-sm", @syncing && "btn-disabled"]}
                    phx-click="sync_definitions"
                    phx-target={@myself}
                    disabled={@syncing}
                  >
                    <%= if @syncing do %>
                      <span class="loading loading-spinner loading-xs"></span> Syncing...
                    <% else %>
                      <.icon name="hero-arrow-path" class="w-4 h-4" /> Sync Library
                    <% end %>
                  </button>
                </div>
              </div>
            </div>
          </div>
          <%!-- Indexer List --%>
          <div class="overflow-y-auto max-h-[50vh]">
            <%= if @definitions == [] do %>
              <div class="alert alert-info">
                <.icon name="hero-information-circle" class="w-5 h-5" />
                <span>
                  <%= if @search_query != "" or @filter_type != "all" or @filter_language != "all" or @filter_enabled != "all" do %>
                    No indexers match your filters. Try adjusting your search criteria.
                  <% else %>
                    No indexer definitions available. Click "Sync Library" to fetch indexers from the repository.
                  <% end %>
                </span>
              </div>
            <% else %>
              <div class="bg-base-200 rounded-box divide-y divide-base-300">
                <%= for definition <- @definitions do %>
                  <div class="p-3 sm:p-4">
                    <div class="flex flex-col sm:flex-row sm:items-center gap-3">
                      <%!-- Indexer Info --%>
                      <div class="flex-1 min-w-0">
                        <div class="font-semibold flex items-center gap-2 flex-wrap">
                          {definition.name}
                          <span class={"badge badge-sm #{indexer_type_badge_class(definition.type)}"}>
                            {definition.type}
                          </span>
                          <%= if definition.language do %>
                            <span class="badge badge-sm badge-ghost">{definition.language}</span>
                          <% end %>
                        </div>
                        <%= if definition.description do %>
                          <div class="text-sm text-base-content/70 mt-1 line-clamp-1">
                            {definition.description}
                          </div>
                        <% end %>
                      </div>
                      <%!-- Actions --%>
                      <div class="flex items-center gap-3">
                        <%!-- Configure button for private indexers --%>
                        <%= if definition.type in ["private", "semi-private"] do %>
                          <button
                            class="btn btn-ghost btn-xs"
                            phx-click="configure_indexer"
                            phx-target={@myself}
                            phx-value-id={definition.id}
                            title="Configure"
                          >
                            <.icon name="hero-cog-6-tooth" class="w-4 h-4" />
                          </button>
                        <% end %>
                        <%!-- Needs config warning --%>
                        <%= if needs_configuration?(definition) and definition.enabled do %>
                          <div class="tooltip" data-tip="This indexer requires configuration">
                            <.icon name="hero-exclamation-triangle" class="w-4 h-4 text-warning" />
                          </div>
                        <% end %>
                        <%!-- Health status --%>
                        <%= if definition.enabled and definition.health_status not in [nil, "unknown"] do %>
                          <span class={"badge badge-sm #{health_status_badge_class(definition.health_status)}"}>
                            {health_status_label(definition.health_status)}
                          </span>
                        <% end %>
                        <%!-- Enable/Disable toggle with status label --%>
                        <label class="flex items-center gap-2 cursor-pointer">
                          <span class={[
                            "text-xs font-medium min-w-14 text-right",
                            if(definition.enabled, do: "text-success", else: "text-base-content/50")
                          ]}>
                            {if definition.enabled, do: "Enabled", else: "Disabled"}
                          </span>
                          <input
                            type="checkbox"
                            class="toggle toggle-success toggle-sm"
                            checked={definition.enabled}
                            phx-click="toggle_indexer"
                            phx-target={@myself}
                            phx-value-id={definition.id}
                          />
                        </label>
                      </div>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
          <%!-- Modal Footer --%>
          <div class="modal-action">
            <button class="btn" phx-click="close_indexer_library">Close</button>
          </div>
        </div>
        <div class="modal-backdrop" phx-click="close_indexer_library"></div>
      </div>
      <%!-- Configuration Modal --%>
      <%= if @configuring_definition do %>
        <div class="modal modal-open" style="z-index: 60;">
          <div class="modal-box">
            <h3 class="font-bold text-lg mb-4">Configure {@configuring_definition.name}</h3>
            <.form
              for={@config_form}
              id="indexer-config-form"
              phx-submit="save_config"
              phx-target={@myself}
              class="space-y-4"
            >
              <input type="hidden" name="definition_id" value={@configuring_definition.id} />
              <div class="form-control">
                <label class="label">
                  <span class="label-text">Username</span>
                </label>
                <input
                  type="text"
                  name="config[username]"
                  value={@config_form[:username].value}
                  class="input input-bordered w-full"
                  placeholder="Enter username"
                />
              </div>
              <div class="form-control">
                <label class="label">
                  <span class="label-text">Password</span>
                </label>
                <input
                  type="password"
                  name="config[password]"
                  value={@config_form[:password].value}
                  class="input input-bordered w-full"
                  placeholder="Enter password"
                />
              </div>
              <div class="modal-action">
                <button
                  type="button"
                  class="btn"
                  phx-click="close_config"
                  phx-target={@myself}
                >
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary">Save</button>
              </div>
            </.form>
          </div>
          <div class="modal-backdrop" phx-click="close_config" phx-target={@myself}></div>
        </div>
      <% end %>
    </div>
    """
  end

  ## Event Handlers

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:filter_type, params["type"] || socket.assigns.filter_type)
     |> assign(:filter_language, params["language"] || socket.assigns.filter_language)
     |> assign(:filter_enabled, params["enabled"] || socket.assigns.filter_enabled)
     |> load_indexers()}
  end

  @impl true
  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, query)
     |> load_indexers()}
  end

  @impl true
  def handle_event("toggle_indexer", %{"id" => id}, socket) do
    definition = Indexers.get_cardigann_definition!(id)

    result =
      if definition.enabled do
        Indexers.disable_cardigann_definition(definition)
      else
        Indexers.enable_cardigann_definition(definition)
      end

    case result do
      {:ok, updated_definition} ->
        action = if updated_definition.enabled, do: "enabled", else: "disabled"

        # Notify the parent LiveView to reload its library indexers data
        send(self(), :reload_library_indexers)

        {:noreply,
         socket
         |> put_flash(:info, "Indexer #{action} successfully")
         |> load_indexers()}

      {:error, changeset} ->
        MydiaLogger.log_error(:liveview, "Failed to toggle indexer",
          error: changeset,
          operation: :toggle_library_indexer,
          definition_id: id,
          user_id: socket.assigns.current_user.id
        )

        error_msg = MydiaLogger.user_error_message(:toggle_library_indexer, changeset)

        {:noreply,
         socket
         |> put_flash(:error, error_msg)}
    end
  end

  @impl true
  def handle_event("sync_definitions", _params, socket) do
    # Run sync in a separate process to avoid blocking the LiveView
    # Use send_update to notify this component when sync completes
    parent = self()
    component_id = socket.assigns.id

    Task.start(fn ->
      result = Mydia.Indexers.DefinitionSync.sync_from_github()
      send(parent, {:sync_complete, component_id, result})
    end)

    {:noreply,
     socket
     |> assign(:syncing, true)
     |> put_flash(:info, "Sync started - this may take a few minutes...")}
  end

  @impl true
  def handle_event("configure_indexer", %{"id" => id}, socket) do
    definition = Indexers.get_cardigann_definition!(id)
    config = definition.config || %{}

    config_form =
      to_form(%{
        "username" => config["username"] || "",
        "password" => config["password"] || ""
      })

    {:noreply,
     socket
     |> assign(:configuring_definition, definition)
     |> assign(:config_form, config_form)}
  end

  @impl true
  def handle_event("close_config", _params, socket) do
    {:noreply,
     socket
     |> assign(:configuring_definition, nil)
     |> assign(:config_form, nil)}
  end

  @impl true
  def handle_event("save_config", %{"definition_id" => id, "config" => config_params}, socket) do
    definition = Indexers.get_cardigann_definition!(id)

    case Indexers.configure_cardigann_definition(definition, config_params) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> assign(:configuring_definition, nil)
         |> assign(:config_form, nil)
         |> put_flash(:info, "Configuration saved successfully")
         |> load_indexers()}

      {:error, changeset} ->
        MydiaLogger.log_error(:liveview, "Failed to save indexer config",
          error: changeset,
          operation: :save_indexer_config,
          definition_id: id,
          user_id: socket.assigns.current_user.id
        )

        error_msg = MydiaLogger.user_error_message(:save_indexer_config, changeset)

        {:noreply,
         socket
         |> put_flash(:error, error_msg)}
    end
  end

  ## Private Functions

  defp load_indexers(socket) do
    filters = build_filters(socket.assigns)
    definitions = Indexers.list_cardigann_definitions(filters)

    # Get unique languages from all definitions for filter dropdown
    all_definitions = Indexers.list_cardigann_definitions()

    languages =
      all_definitions
      |> Enum.map(& &1.language)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    socket
    |> assign(:definitions, definitions)
    |> assign(:available_languages, languages)
  end

  defp build_filters(assigns) do
    filters = []

    filters =
      if assigns.filter_type != "all" do
        [{:type, assigns.filter_type} | filters]
      else
        filters
      end

    filters =
      if assigns.filter_language != "all" do
        [{:language, assigns.filter_language} | filters]
      else
        filters
      end

    filters =
      case assigns.filter_enabled do
        "enabled" -> [{:enabled, true} | filters]
        "disabled" -> [{:enabled, false} | filters]
        _ -> filters
      end

    filters =
      if assigns.search_query != "" do
        [{:search, assigns.search_query} | filters]
      else
        filters
      end

    filters
  end

  defp indexer_type_badge_class("public"), do: "badge-success"
  defp indexer_type_badge_class("private"), do: "badge-error"
  defp indexer_type_badge_class("semi-private"), do: "badge-warning"
  defp indexer_type_badge_class(_), do: "badge-ghost"

  defp needs_configuration?(%CardigannDefinition{type: "public"}), do: false

  defp needs_configuration?(%CardigannDefinition{
         type: type,
         config: nil
       })
       when type in ["private", "semi-private"],
       do: true

  defp needs_configuration?(%CardigannDefinition{type: type, config: config})
       when type in ["private", "semi-private"] and config == %{},
       do: true

  defp needs_configuration?(_), do: false

  defp health_status_badge_class("healthy"), do: "badge-success"
  defp health_status_badge_class("degraded"), do: "badge-warning"
  defp health_status_badge_class("unhealthy"), do: "badge-error"
  defp health_status_badge_class("unknown"), do: "badge-ghost"
  defp health_status_badge_class(_), do: "badge-ghost"

  defp health_status_label("healthy"), do: "Healthy"
  defp health_status_label("degraded"), do: "Degraded"
  defp health_status_label("unhealthy"), do: "Unhealthy"
  defp health_status_label("unknown"), do: "Unknown"
  defp health_status_label(nil), do: "Unknown"
  defp health_status_label(_), do: "Unknown"

  defp format_sync_error(:rate_limit_exceeded),
    do: "GitHub API rate limit exceeded. Try again later."

  defp format_sync_error(:not_found), do: "Repository or definitions path not found."
  defp format_sync_error({:unexpected_status, status}), do: "Unexpected HTTP status: #{status}"
  defp format_sync_error(reason) when is_binary(reason), do: reason
  defp format_sync_error(reason), do: inspect(reason)
end
