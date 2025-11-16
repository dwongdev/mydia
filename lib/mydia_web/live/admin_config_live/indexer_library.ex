defmodule MydiaWeb.AdminConfigLive.IndexerLibrary do
  use MydiaWeb, :live_view
  alias Mydia.Indexers
  alias Mydia.Indexers.CardigannFeatureFlags
  alias Mydia.Indexers.CardigannDefinition

  require Logger
  alias Mydia.Logger, as: MydiaLogger

  @impl true
  def mount(_params, _session, socket) do
    # Feature flag check - redirect if disabled
    unless CardigannFeatureFlags.enabled?() do
      {:ok, push_navigate(socket, to: ~p"/admin/config")}
    else
      {:ok,
       socket
       |> assign(:page_title, "Cardigann Indexer Library")
       |> assign(:filter_type, "all")
       |> assign(:filter_language, "all")
       |> assign(:filter_enabled, "all")
       |> assign(:search_query, "")
       |> assign(:show_config_modal, false)
       |> load_indexers()}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  ## Event Handlers

  @impl true
  def handle_event("filter_type", %{"type" => type}, socket) do
    {:noreply,
     socket
     |> assign(:filter_type, type)
     |> load_indexers()}
  end

  @impl true
  def handle_event("filter_language", %{"language" => language}, socket) do
    {:noreply,
     socket
     |> assign(:filter_language, language)
     |> load_indexers()}
  end

  @impl true
  def handle_event("filter_enabled", %{"enabled" => enabled}, socket) do
    {:noreply,
     socket
     |> assign(:filter_enabled, enabled)
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

        {:noreply,
         socket
         |> put_flash(:info, "Indexer #{action} successfully")
         |> load_indexers()}

      {:error, changeset} ->
        MydiaLogger.log_error(:liveview, "Failed to toggle indexer",
          error: changeset,
          operation: :toggle_cardigann_indexer,
          definition_id: id,
          user_id: socket.assigns.current_user.id
        )

        error_msg = MydiaLogger.user_error_message(:toggle_cardigann_indexer, changeset)

        {:noreply,
         socket
         |> put_flash(:error, error_msg)}
    end
  end

  @impl true
  def handle_event("configure_indexer", %{"id" => id}, socket) do
    definition = Indexers.get_cardigann_definition!(id)

    {:noreply,
     socket
     |> assign(:show_config_modal, true)
     |> assign(:configuring_definition, definition)}
  end

  @impl true
  def handle_event("close_config_modal", _params, socket) do
    {:noreply, assign(socket, :show_config_modal, false)}
  end

  @impl true
  def handle_event("save_config", %{"config" => config_params}, socket) do
    definition = socket.assigns.configuring_definition

    case Indexers.configure_cardigann_definition(definition, config_params) do
      {:ok, _updated_definition} ->
        {:noreply,
         socket
         |> assign(:show_config_modal, false)
         |> put_flash(:info, "Configuration saved successfully")
         |> load_indexers()}

      {:error, changeset} ->
        MydiaLogger.log_error(:liveview, "Failed to configure indexer",
          error: changeset,
          operation: :configure_cardigann_indexer,
          definition_id: definition.id,
          user_id: socket.assigns.current_user.id
        )

        error_msg = MydiaLogger.user_error_message(:configure_cardigann_indexer, changeset)

        {:noreply,
         socket
         |> put_flash(:error, error_msg)}
    end
  end

  @impl true
  def handle_event("sync_definitions", _params, socket) do
    # Trigger manual sync (this will be handled by the DefinitionSync module)
    # For now, just show a message
    {:noreply,
     socket
     |> put_flash(:info, "Sync triggered - this may take a few minutes")}
  end

  ## Private Functions

  defp load_indexers(socket) do
    filters = build_filters(socket.assigns)
    definitions = Indexers.list_cardigann_definitions(filters)
    stats = Indexers.count_cardigann_definitions()

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
    |> assign(:stats, stats)
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

  defp indexer_status_class(%CardigannDefinition{enabled: false}), do: "badge-ghost"

  defp indexer_status_class(%CardigannDefinition{enabled: true, type: "private", config: nil}),
    do: "badge-warning"

  defp indexer_status_class(%CardigannDefinition{enabled: true, type: "private", config: config})
       when config == %{},
       do: "badge-warning"

  defp indexer_status_class(%CardigannDefinition{enabled: true}), do: "badge-success"

  defp indexer_status_label(%CardigannDefinition{enabled: false}), do: "Disabled"

  defp indexer_status_label(%CardigannDefinition{enabled: true, type: "private", config: nil}),
    do: "Needs Config"

  defp indexer_status_label(%CardigannDefinition{enabled: true, type: "private", config: config})
       when config == %{},
       do: "Needs Config"

  defp indexer_status_label(%CardigannDefinition{enabled: true}), do: "Enabled"

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
end
