defmodule MydiaWeb.MusicPlayerLive do
  use MydiaWeb, :live_view

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Mydia.PubSub, "music_player")
    end

    {:ok,
     socket
     |> assign(:current_track, nil)
     |> assign(:is_playing, false)
     |> assign(:visible, false)}
  end

  def render(assigns) do
    ~H"""
    <div
      id="music-player-container"
      phx-hook="MusicPlayer"
      class={
        if @visible,
          do:
            "fixed bottom-0 w-full bg-base-100 border-t border-base-300 p-2 z-50 shadow-[0_-4px_6px_-1px_rgba(0,0,0,0.1)]",
          else: "hidden"
      }
    >
      <audio></audio>

      <div class="flex items-center justify-between max-w-7xl mx-auto px-4">
        <!-- Track Info -->
        <div class="flex items-center gap-4 w-1/3">
          <%= if @current_track do %>
            <%= if @current_track["cover_url"] do %>
              <img src={@current_track["cover_url"]} class="w-12 h-12 rounded object-cover" />
            <% end %>
            <div class="overflow-hidden">
              <div class="font-bold truncate">{@current_track["title"]}</div>
              <div class="text-sm truncate opacity-70">{@current_track["artist_name"]}</div>
            </div>
          <% end %>
        </div>
        
    <!-- Controls -->
        <div class="flex gap-4 justify-center w-1/3">
          <button
            class="btn btn-ghost btn-circle btn-sm"
            phx-click={JS.dispatch("music:prev", to: "#music-player-container")}
          >
            <.icon name="hero-backward" class="w-5 h-5" />
          </button>
          <button
            class="btn btn-primary btn-circle"
            phx-click={JS.dispatch("music:toggle", to: "#music-player-container")}
          >
            <.icon name={if @is_playing, do: "hero-pause", else: "hero-play"} class="w-6 h-6" />
          </button>
          <button
            class="btn btn-ghost btn-circle btn-sm"
            phx-click={JS.dispatch("music:next", to: "#music-player-container")}
          >
            <.icon name="hero-forward" class="w-5 h-5" />
          </button>
        </div>
        
    <!-- Progress -->
        <div
          class="w-1/3 flex items-center gap-2"
          x-data="{ progress: 0 }"
          @music:timeupdate.window="progress = ($event.detail.currentTime / $event.detail.duration) * 100 || 0"
        >
          <progress class="progress progress-primary w-full" x-bind:value="progress" max="100">
          </progress>
        </div>
      </div>
    </div>
    """
  end

  def handle_info({:play_tracks, tracks, start_index}, socket) do
    {:noreply,
     socket
     |> assign(:visible, true)
     |> push_event("music:play", %{tracks: tracks, start_index: start_index})}
  end

  def handle_event("music:track_changed", %{"track" => track}, socket) do
    {:noreply, assign(socket, :current_track, track)}
  end

  def handle_event("music:state_sync", %{"is_playing" => is_playing}, socket) do
    {:noreply, assign(socket, :is_playing, is_playing)}
  end
end
