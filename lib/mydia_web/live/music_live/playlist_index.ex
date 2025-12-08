defmodule MydiaWeb.MusicLive.PlaylistIndex do
  use MydiaWeb, :live_view

  alias Mydia.Music

  import MydiaWeb.PlaylistComponents

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    playlists = Music.list_user_playlists(user.id)

    {:ok,
     socket
     |> assign(:page_title, "Playlists")
     |> assign(:playlists, playlists)
     |> assign(:show_create_modal, false)
     |> assign(:form, to_form(Music.change_playlist(%Music.Playlist{})))}
  end

  @impl true
  def handle_event("open_create_modal", _params, socket) do
    {:noreply, assign(socket, :show_create_modal, true)}
  end

  def handle_event("close_create_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_create_modal, false)
     |> assign(:form, to_form(Music.change_playlist(%Music.Playlist{})))}
  end

  def handle_event("validate", %{"playlist" => params}, socket) do
    form =
      %Music.Playlist{}
      |> Music.change_playlist(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("create_playlist", %{"playlist" => params}, socket) do
    user = socket.assigns.current_scope.user

    case Music.create_playlist(user, params) do
      {:ok, _playlist} ->
        playlists = Music.list_user_playlists(user.id)

        {:noreply,
         socket
         |> assign(:playlists, playlists)
         |> assign(:show_create_modal, false)
         |> assign(:form, to_form(Music.change_playlist(%Music.Playlist{})))
         |> put_flash(:info, "Playlist created successfully")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex flex-col h-full">
        <%!-- Header --%>
        <div class="flex items-center justify-between mb-6">
          <div>
            <.link navigate={~p"/music"} class="btn btn-ghost btn-sm gap-2 mb-2">
              <.icon name="hero-arrow-left" class="w-4 h-4" /> Back to Music
            </.link>
            <h1 class="text-3xl font-bold">Playlists</h1>
          </div>
          <button type="button" phx-click="open_create_modal" class="btn btn-primary gap-2">
            <.icon name="hero-plus" class="w-5 h-5" /> New Playlist
          </button>
        </div>

        <%!-- Playlist grid --%>
        <%= if @playlists == [] do %>
          <div class="flex flex-col items-center justify-center py-16">
            <.icon name="hero-musical-note" class="w-16 h-16 text-base-content/20 mb-4" />
            <h2 class="text-xl font-semibold mb-2">No playlists yet</h2>
            <p class="text-base-content/60 mb-4">Create your first playlist to organize your music</p>
            <button type="button" phx-click="open_create_modal" class="btn btn-primary gap-2">
              <.icon name="hero-plus" class="w-5 h-5" /> Create Playlist
            </button>
          </div>
        <% else %>
          <div class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-4">
            <%= for playlist <- @playlists do %>
              <.playlist_card playlist={playlist} />
            <% end %>
          </div>
        <% end %>
      </div>

      <%!-- Create Playlist Modal --%>
      <%= if @show_create_modal do %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg mb-4">Create New Playlist</h3>
            <.form
              for={@form}
              phx-submit="create_playlist"
              phx-change="validate"
              id="create-playlist-form"
            >
              <div class="form-control mb-4">
                <.input
                  field={@form[:name]}
                  type="text"
                  label="Name"
                  placeholder="My Playlist"
                  required
                />
              </div>
              <div class="form-control mb-4">
                <.input
                  field={@form[:description]}
                  type="textarea"
                  label="Description (optional)"
                  placeholder="Add a description..."
                />
              </div>
              <div class="modal-action">
                <button type="button" phx-click="close_create_modal" class="btn btn-ghost">
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary">
                  Create
                </button>
              </div>
            </.form>
          </div>
          <div class="modal-backdrop" phx-click="close_create_modal"></div>
        </div>
      <% end %>
    </Layouts.app>
    """
  end
end
