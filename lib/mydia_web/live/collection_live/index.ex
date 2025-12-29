defmodule MydiaWeb.CollectionLive.Index do
  @moduledoc """
  LiveView for browsing and managing collections.

  Supports:
  - Grid/list view toggle
  - Filtering by collection type and visibility
  - Creating new collections via modal
  - Navigation to collection detail
  """
  use MydiaWeb, :live_view

  alias Mydia.Collections
  alias Mydia.Collections.Collection

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:view_mode, :grid)
     |> assign(:search_query, "")
     |> assign(:filter_type, nil)
     |> assign(:filter_visibility, nil)
     |> assign(:show_new_modal, false)
     |> assign(:new_collection_type, "manual")
     |> assign(:new_form, to_form(%{}, as: :collection))
     |> assign(:collections_empty?, true)
     |> stream(:collections, [])}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply,
     socket
     |> assign(:page_title, "Collections")
     |> load_collections()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {assigns}>
      <div class="container mx-auto px-4 py-6">
        <%!-- Header --%>
        <div class="flex flex-col md:flex-row md:items-center justify-between gap-4 mb-6">
          <div>
            <h1 class="text-2xl font-bold">Collections</h1>
            <p class="text-base-content/60">Organize your media into custom groups</p>
          </div>
          <div class="flex items-center gap-2">
            <.view_mode_toggle view_mode={@view_mode} />
            <button
              type="button"
              class="btn btn-primary gap-2"
              phx-click="open_new_modal"
            >
              <.icon name="hero-plus" class="w-5 h-5" /> New Collection
            </button>
          </div>
        </div>

        <%!-- Filters --%>
        <.collection_filters
          search_query={@search_query}
          filter_type={@filter_type}
          filter_visibility={@filter_visibility}
        />

        <%!-- Collections Grid/List --%>
        <%= if @view_mode == :grid do %>
          <.collection_grid id="collections-grid" collections={@streams.collections}>
            <:collection :let={collection}>
              <.collection_card
                collection={collection}
                href={~p"/collections/#{collection.id}"}
                item_count={collection.item_count || 0}
                poster_url={collection.poster_path}
              />
            </:collection>
          </.collection_grid>
        <% else %>
          <.collection_list id="collections-list" collections={@streams.collections}>
            <:collection :let={collection}>
              <.collection_row
                collection={collection}
                href={~p"/collections/#{collection.id}"}
                item_count={collection.item_count || 0}
                poster_url={collection.poster_path}
              />
            </:collection>
          </.collection_list>
        <% end %>

        <%!-- Empty state --%>
        <div
          :if={@collections_empty?}
          class="text-center py-12"
          id="empty-state"
        >
          <.collection_empty_state message="No collections found">
            <:actions>
              <button
                type="button"
                class="btn btn-primary gap-2"
                phx-click="open_new_modal"
              >
                <.icon name="hero-plus" class="w-5 h-5" /> Create your first collection
              </button>
            </:actions>
          </.collection_empty_state>
        </div>

        <%!-- New Collection Modal --%>
        <.modal
          :if={@show_new_modal}
          id="new-collection-modal"
          show={@show_new_modal}
          on_cancel={JS.push("close_new_modal")}
        >
          <:title>Create New Collection</:title>

          <.form
            for={@new_form}
            phx-submit="create_collection"
            phx-change="validate_collection"
            id="new-collection-form"
          >
            <div class="space-y-4">
              <%!-- Collection Type --%>
              <.type_selector
                selected={@new_collection_type}
                name="collection[type]"
              />

              <%!-- Name --%>
              <div>
                <label class="label">
                  <span class="label-text font-medium">Name</span>
                </label>
                <input
                  type="text"
                  name="collection[name]"
                  value={@new_form[:name].value}
                  class="input input-bordered w-full"
                  placeholder="My Collection"
                  required
                />
              </div>

              <%!-- Description --%>
              <div>
                <label class="label">
                  <span class="label-text font-medium">Description</span>
                  <span class="label-text-alt">Optional</span>
                </label>
                <textarea
                  name="collection[description]"
                  class="textarea textarea-bordered w-full"
                  placeholder="What's this collection about?"
                  rows="2"
                >{@new_form[:description].value}</textarea>
              </div>

              <%!-- Visibility (Admin only) --%>
              <%= if @current_user.role == "admin" do %>
                <div>
                  <label class="label">
                    <span class="label-text font-medium">Visibility</span>
                  </label>
                  <select name="collection[visibility]" class="select select-bordered w-full">
                    <option value="private" selected={@new_form[:visibility].value != "shared"}>
                      Private - Only you can see this
                    </option>
                    <option value="shared" selected={@new_form[:visibility].value == "shared"}>
                      Shared - Visible to all users
                    </option>
                  </select>
                </div>
              <% end %>

              <%!-- Smart Rules (shown for smart collections) --%>
              <%= if @new_collection_type == "smart" do %>
                <div class="divider">Smart Rules</div>
                <p class="text-sm text-base-content/60">
                  Configure the filter rules after creating the collection.
                </p>
              <% end %>
            </div>
          </.form>

          <:actions>
            <button type="button" class="btn btn-ghost" phx-click="close_new_modal">
              Cancel
            </button>
            <button type="submit" form="new-collection-form" class="btn btn-primary">
              <.icon name="hero-plus" class="w-4 h-4" /> Create Collection
            </button>
          </:actions>
        </.modal>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("toggle_view", %{"mode" => mode}, socket) do
    view_mode = String.to_existing_atom(mode)
    {:noreply, assign(socket, :view_mode, view_mode)}
  end

  def handle_event("search", %{"search" => query}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, query)
     |> load_collections()}
  end

  def handle_event("filter", params, socket) do
    filter_type =
      case params["type"] do
        "" -> nil
        type when type in ["manual", "smart"] -> type
        _ -> nil
      end

    filter_visibility =
      case params["visibility"] do
        "" -> nil
        vis when vis in ["private", "shared"] -> vis
        _ -> nil
      end

    {:noreply,
     socket
     |> assign(:filter_type, filter_type)
     |> assign(:filter_visibility, filter_visibility)
     |> load_collections()}
  end

  def handle_event("open_new_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_new_modal, true)
     |> assign(:new_collection_type, "manual")
     |> assign(:new_form, to_form(%{}, as: :collection))}
  end

  def handle_event("close_new_modal", _params, socket) do
    {:noreply, assign(socket, :show_new_modal, false)}
  end

  def handle_event("validate_collection", %{"collection" => params}, socket) do
    new_type = params["type"] || socket.assigns.new_collection_type

    {:noreply,
     socket
     |> assign(:new_collection_type, new_type)
     |> assign(:new_form, to_form(params, as: :collection))}
  end

  def handle_event("create_collection", %{"collection" => params}, socket) do
    user = socket.assigns.current_user

    attrs = %{
      name: params["name"],
      description: params["description"],
      type: params["type"] || "manual",
      visibility: params["visibility"] || "private"
    }

    case Collections.create_collection(user, attrs) do
      {:ok, collection} ->
        {:noreply,
         socket
         |> put_flash(:info, "Collection created successfully")
         |> assign(:show_new_modal, false)
         |> push_navigate(to: ~p"/collections/#{collection.id}")}

      {:error, :unauthorized} ->
        {:noreply,
         put_flash(socket, :error, "You don't have permission to create shared collections")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to create collection")
         |> assign(:new_form, to_form(changeset, as: :collection))}
    end
  end

  # Private helpers

  defp load_collections(socket) do
    user = socket.assigns.current_user

    opts =
      []
      |> maybe_add_filter(:type, socket.assigns.filter_type)
      |> maybe_add_filter(:visibility, socket.assigns.filter_visibility)

    collections =
      user
      |> Collections.list_collections(opts)
      |> filter_by_search(socket.assigns.search_query)
      |> Enum.map(&add_item_count/1)

    socket
    |> assign(:collections_empty?, collections == [])
    |> stream(:collections, collections, reset: true)
  end

  defp maybe_add_filter(opts, _key, nil), do: opts
  defp maybe_add_filter(opts, key, value), do: Keyword.put(opts, key, value)

  defp filter_by_search(collections, ""), do: collections
  defp filter_by_search(collections, nil), do: collections

  defp filter_by_search(collections, query) do
    query = String.downcase(query)

    Enum.filter(collections, fn collection ->
      String.contains?(String.downcase(collection.name), query)
    end)
  end

  defp add_item_count(%Collection{} = collection) do
    count = Collections.item_count(collection)
    Map.put(collection, :item_count, count)
  end
end
