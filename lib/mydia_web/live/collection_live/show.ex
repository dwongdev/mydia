defmodule MydiaWeb.CollectionLive.Show do
  @moduledoc """
  LiveView for viewing and managing a single collection.

  Supports:
  - Viewing collection items (manual) or matching items (smart)
  - Editing collection settings
  - Managing smart rules for smart collections
  - Adding/removing items from manual collections
  - Reordering items in manual collections
  """
  use MydiaWeb, :live_view

  alias Mydia.Collections
  alias Mydia.Collections.Collection

  @items_per_page 50

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    case Collections.get_collection(user, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Collection not found")
         |> push_navigate(to: ~p"/collections")}

      collection ->
        {:ok,
         socket
         |> assign(:collection, collection)
         |> assign(:page_title, collection.name)
         |> assign(:page, 0)
         |> assign(:has_more, true)
         |> assign(:show_edit_modal, false)
         |> assign(:show_delete_modal, false)
         |> assign(:edit_form, to_form(%{}, as: :collection))
         |> stream(:items, [])
         |> load_items(reset: true)}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {assigns}>
      <div class="container mx-auto px-4 py-6">
        <%!-- Header --%>
        <div class="flex flex-col md:flex-row md:items-center justify-between gap-4 mb-6">
          <div class="flex items-center gap-4">
            <.link navigate={~p"/collections"} class="btn btn-ghost btn-sm btn-circle">
              <.icon name="hero-arrow-left" class="w-5 h-5" />
            </.link>
            <div>
              <div class="flex items-center gap-2">
                <h1 class="text-2xl font-bold">{@collection.name}</h1>
                <%= if @collection.is_system do %>
                  <span class="badge badge-ghost gap-1">
                    <.icon name="hero-star" class="w-3 h-3" />
                    System
                  </span>
                <% end %>
                <span class={["badge badge-sm gap-1", type_badge_class(@collection.type)]}>
                  <.icon name={type_icon(@collection.type)} class="w-3 h-3" />
                  {type_label(@collection.type)}
                </span>
              </div>
              <%= if @collection.description do %>
                <p class="text-base-content/60">{@collection.description}</p>
              <% end %>
            </div>
          </div>
          <div class="flex items-center gap-2">
            <span class="text-base-content/60">
              {@item_count} {if @item_count == 1, do: "item", else: "items"}
            </span>
            <%!-- Smart collection: Edit Rules button --%>
            <%= if @collection.type == "smart" do %>
              <button
                type="button"
                class="btn btn-ghost btn-sm gap-1"
                phx-click="open_edit_modal"
              >
                <.icon name="hero-funnel" class="w-4 h-4" />
                Edit Rules
              </button>
            <% end %>
            <%!-- Settings dropdown for non-system collections --%>
            <%= if not @collection.is_system and can_edit?(@collection, @current_user) do %>
              <div class="dropdown dropdown-end">
                <label tabindex="0" class="btn btn-ghost btn-sm gap-1">
                  <.icon name="hero-ellipsis-vertical" class="w-5 h-5" />
                </label>
                <ul tabindex="0" class="dropdown-content z-[1] menu p-2 shadow bg-base-100 rounded-box w-52">
                  <li>
                    <button type="button" phx-click="open_edit_modal">
                      <.icon name="hero-pencil" class="w-4 h-4" />
                      Edit Collection
                    </button>
                  </li>
                  <li>
                    <button type="button" phx-click="open_delete_modal" class="text-error">
                      <.icon name="hero-trash" class="w-4 h-4" />
                      Delete Collection
                    </button>
                  </li>
                </ul>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Items Grid with infinite scroll --%>
        <div
          id="collection-items"
          phx-update="stream"
          phx-viewport-bottom={@has_more && "load_more"}
          class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-3 md:gap-4"
        >
          <div :for={{id, item} <- @streams.items} id={id} class="relative group">
            <%!-- Remove button for manual collections --%>
            <%= if @collection.type == "manual" and can_edit?(@collection, @current_user) do %>
              <button
                type="button"
                phx-click="remove_item"
                phx-value-id={item.id}
                class="absolute top-2 right-2 z-10 btn btn-circle btn-xs btn-error opacity-0 group-hover:opacity-100 transition-opacity"
                title="Remove from collection"
              >
                <.icon name="hero-x-mark" class="w-3 h-3" />
              </button>
            <% end %>

            <.link navigate={item_href(item)} class="block">
              <div class="card bg-base-100 shadow-lg hover:shadow-xl transition-shadow duration-200">
                <figure class="relative aspect-[2/3] overflow-hidden bg-base-300">
                  <img
                    :if={item.poster_url}
                    src={item.poster_url}
                    alt={item.title}
                    class="w-full h-full object-cover group-hover:scale-105 transition-transform duration-300"
                    loading="lazy"
                  />
                  <div
                    :if={!item.poster_url}
                    class="w-full h-full flex items-center justify-center"
                  >
                    <.icon name="hero-film" class="w-12 h-12 text-base-content/20" />
                  </div>
                </figure>
                <div class="card-body p-3">
                  <h3 class="card-title text-sm line-clamp-2">{item.title}</h3>
                  <span class="text-xs text-base-content/70">{item.year}</span>
                </div>
              </div>
            </.link>
          </div>
        </div>

        <%!-- Loading indicator --%>
        <div :if={@has_more} class="flex justify-center py-8">
          <span class="loading loading-spinner loading-md text-primary"></span>
        </div>

        <%!-- Empty state --%>
        <div
          :if={stream_empty?(@streams.items)}
          class="flex flex-col items-center justify-center py-16"
        >
          <.icon name="hero-film" class="w-16 h-16 mb-4 text-base-content/30" />
          <h3 class="text-xl font-semibold text-base-content/70 mb-2">No items yet</h3>
          <p class="text-base-content/50 text-center max-w-md">
            <%= if @collection.type == "smart" do %>
              No items match your smart rules. Try adjusting the conditions.
            <% else %>
              Add items to this collection from any media detail page.
            <% end %>
          </p>
        </div>

        <%!-- Edit Collection Modal --%>
        <.modal
          :if={@show_edit_modal}
          id="edit-collection-modal"
          show={@show_edit_modal}
          on_cancel={JS.push("close_edit_modal")}
        >
          <:title>Edit Collection</:title>

          <.form for={@edit_form} phx-submit="update_collection" id="edit-collection-form">
            <div class="space-y-4">
              <%!-- Name --%>
              <div>
                <label class="label">
                  <span class="label-text font-medium">Name</span>
                </label>
                <input
                  type="text"
                  name="collection[name]"
                  value={@collection.name}
                  class="input input-bordered w-full"
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
                  rows="2"
                >{@collection.description}</textarea>
              </div>

              <%!-- Visibility (Admin only) --%>
              <%= if @current_user.role == "admin" do %>
                <div>
                  <label class="label">
                    <span class="label-text font-medium">Visibility</span>
                  </label>
                  <select name="collection[visibility]" class="select select-bordered w-full">
                    <option value="private" selected={@collection.visibility == "private"}>
                      Private - Only you can see this
                    </option>
                    <option value="shared" selected={@collection.visibility == "shared"}>
                      Shared - Visible to all users
                    </option>
                  </select>
                </div>
              <% end %>

              <%!-- Smart Rules for smart collections --%>
              <%= if @collection.type == "smart" do %>
                <div class="divider">Smart Rules</div>
                <p class="text-sm text-base-content/60 mb-4">
                  Smart rules editor coming soon. For now, edit the JSON directly:
                </p>
                <textarea
                  name="collection[smart_rules]"
                  class="textarea textarea-bordered w-full font-mono text-sm"
                  rows="8"
                >{@collection.smart_rules || "{}"}</textarea>
              <% end %>
            </div>
          </.form>

          <:actions>
            <button type="button" class="btn btn-ghost" phx-click="close_edit_modal">
              Cancel
            </button>
            <button type="submit" form="edit-collection-form" class="btn btn-primary">
              Save Changes
            </button>
          </:actions>
        </.modal>

        <%!-- Delete Confirmation Modal --%>
        <.modal
          :if={@show_delete_modal}
          id="delete-collection-modal"
          show={@show_delete_modal}
          on_cancel={JS.push("close_delete_modal")}
        >
          <:title>Delete Collection?</:title>

          <p class="text-base-content/70">
            Are you sure you want to delete <strong>{@collection.name}</strong>?
            This action cannot be undone.
          </p>
          <p class="text-sm text-base-content/50 mt-2">
            The media items in this collection will not be deleted.
          </p>

          <:actions>
            <button type="button" class="btn btn-ghost" phx-click="close_delete_modal">
              Cancel
            </button>
            <button type="button" class="btn btn-error" phx-click="delete_collection">
              <.icon name="hero-trash" class="w-4 h-4" />
              Delete Collection
            </button>
          </:actions>
        </.modal>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more do
      {:noreply,
       socket
       |> update(:page, &(&1 + 1))
       |> load_items(reset: false)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_item", %{"id" => item_id}, socket) do
    collection = socket.assigns.collection
    user = socket.assigns.current_user

    if can_edit?(collection, user) do
      case Collections.remove_item(collection, item_id) do
        {:ok, _} ->
          {:noreply,
           socket
           |> stream_delete(:items, %{id: item_id})
           |> update(:item_count, &(&1 - 1))
           |> put_flash(:info, "Item removed from collection")}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "Item not found in collection")}

        {:error, :smart_collection} ->
          {:noreply, put_flash(socket, :error, "Cannot remove items from smart collections")}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to edit this collection")}
    end
  end

  def handle_event("open_edit_modal", _params, socket) do
    {:noreply, assign(socket, :show_edit_modal, true)}
  end

  def handle_event("close_edit_modal", _params, socket) do
    {:noreply, assign(socket, :show_edit_modal, false)}
  end

  def handle_event("open_delete_modal", _params, socket) do
    {:noreply, assign(socket, :show_delete_modal, true)}
  end

  def handle_event("close_delete_modal", _params, socket) do
    {:noreply, assign(socket, :show_delete_modal, false)}
  end

  def handle_event("update_collection", %{"collection" => params}, socket) do
    collection = socket.assigns.collection
    user = socket.assigns.current_user

    attrs = %{
      name: params["name"],
      description: params["description"],
      visibility: params["visibility"],
      smart_rules: params["smart_rules"]
    }

    case Collections.update_collection(user, collection, attrs) do
      {:ok, updated_collection} ->
        {:noreply,
         socket
         |> assign(:collection, updated_collection)
         |> assign(:page_title, updated_collection.name)
         |> assign(:show_edit_modal, false)
         |> put_flash(:info, "Collection updated")
         |> load_items(reset: true)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to edit this collection")}

      {:error, :system_collection} ->
        {:noreply, put_flash(socket, :error, "System collections cannot be edited")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Failed to update collection")}
    end
  end

  def handle_event("delete_collection", _params, socket) do
    collection = socket.assigns.collection
    user = socket.assigns.current_user

    case Collections.delete_collection(user, collection) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Collection deleted")
         |> push_navigate(to: ~p"/collections")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to delete this collection")}

      {:error, :system_collection} ->
        {:noreply, put_flash(socket, :error, "System collections cannot be deleted")}
    end
  end

  # Private helpers

  defp load_items(socket, opts) do
    reset = Keyword.get(opts, :reset, false)
    collection = socket.assigns.collection
    page = if reset, do: 0, else: socket.assigns.page
    offset = page * @items_per_page

    items = Collections.list_collection_items(collection, limit: @items_per_page, offset: offset)
    item_count = Collections.item_count(collection)

    items_with_metadata =
      Enum.map(items, fn item ->
        %{
          id: item.id,
          title: item.title,
          year: item.year,
          type: item.type,
          poster_url: build_poster_url(item)
        }
      end)

    has_more = length(items) == @items_per_page

    socket
    |> assign(:item_count, item_count)
    |> assign(:has_more, has_more)
    |> assign(:page, page)
    |> stream(:items, items_with_metadata, reset: reset)
  end

  defp build_poster_url(%{metadata: %{"poster_path" => path}}) when is_binary(path) do
    "https://image.tmdb.org/t/p/w342#{path}"
  end

  defp build_poster_url(%{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "poster_path") || Map.get(metadata, :poster_path) do
      nil -> nil
      path -> "https://image.tmdb.org/t/p/w342#{path}"
    end
  end

  defp build_poster_url(_), do: nil

  defp item_href(%{type: "movie", id: id}), do: ~p"/movies/#{id}"
  defp item_href(%{type: "tv_show", id: id}), do: ~p"/tv/#{id}"
  defp item_href(%{id: id}), do: ~p"/media/#{id}"

  defp can_edit?(%Collection{user_id: user_id}, %{id: current_user_id}) do
    user_id == current_user_id
  end

  defp stream_empty?({_, []}), do: true
  defp stream_empty?(_), do: false

  defp type_badge_class("smart"), do: "badge-secondary"
  defp type_badge_class("manual"), do: "badge-primary"
  defp type_badge_class(_), do: "badge-ghost"

  defp type_icon("smart"), do: "hero-sparkles"
  defp type_icon("manual"), do: "hero-folder"
  defp type_icon(_), do: "hero-folder"

  defp type_label("smart"), do: "Smart"
  defp type_label("manual"), do: "Manual"
  defp type_label(_), do: "Manual"
end
