defmodule MydiaWeb.MediaLive.Show.Components do
  @moduledoc """
  UI component sections for the MediaLive.Show page.
  """
  use MydiaWeb, :html
  import MydiaWeb.MediaLive.Show.Formatters
  import MydiaWeb.MediaLive.Show.Helpers

  @doc """
  Hero section with backdrop image, poster, and quick action buttons.
  """
  attr :media_item, :map, required: true
  attr :playback_enabled, :boolean, required: true
  attr :next_episode, :map, default: nil
  attr :next_episode_state, :atom, default: nil
  attr :auto_searching, :boolean, required: true
  attr :downloads_with_status, :list, required: true
  attr :quality_profiles, :list, required: true

  def hero_section(assigns) do
    ~H"""
    <%!-- Left Column: Poster and Quick Actions --%>
    <div class="w-full md:w-64 lg:w-80 flex-shrink-0">
      <%!-- Poster - centered and smaller on mobile --%>
      <div class="card bg-base-100 shadow-xl mb-4 mx-auto w-48 sm:w-56 md:w-full">
        <figure class="aspect-[2/3] bg-base-300">
          <img
            src={get_poster_url(@media_item)}
            alt={@media_item.title}
            class="w-full h-full object-cover"
          />
        </figure>
      </div>

      <%!-- Quick Actions --%>
      <div class="flex flex-col gap-2">
        <%!-- Play Button (for content with media files) --%>
        <%= if @playback_enabled && @media_item.type == "movie" && length(@media_item.media_files) > 0 do %>
          <.link navigate={~p"/play/movie/#{@media_item.id}"} class="btn btn-primary btn-block">
            <.icon name="hero-play-circle-solid" class="w-5 h-5" /> Play Movie
          </.link>

          <div class="divider my-1"></div>
        <% end %>

        <%!-- Play Next Button (for TV shows with next episode) --%>
        <%= if @playback_enabled && @media_item.type == "tv_show" && @next_episode do %>
          <.link navigate={~p"/play/episode/#{@next_episode.id}"} class="btn btn-primary btn-block">
            <.icon name="hero-play-circle-solid" class="w-5 h-5" />
            {next_episode_button_text(@next_episode_state)}
          </.link>

          <div class="divider my-1"></div>
        <% end %>

        <button
          type="button"
          phx-click="auto_search_download"
          class="btn btn-primary btn-block"
          disabled={@auto_searching || !can_auto_search?(@media_item, @downloads_with_status)}
        >
          <%= if @auto_searching do %>
            <span class="loading loading-spinner loading-sm"></span> Searching...
          <% else %>
            <.icon name="hero-bolt" class="w-5 h-5" /> Auto Search & Download
          <% end %>
        </button>

        <button type="button" phx-click="manual_search" class="btn btn-outline btn-block">
          <.icon name="hero-magnifying-glass" class="w-5 h-5" /> Manual Search
        </button>

        <%!-- Secondary actions: 2-column on mobile, stacked on desktop --%>
        <div class="grid grid-cols-2 md:grid-cols-1 gap-2">
          <button
            type="button"
            phx-click="toggle_monitored"
            class={[
              "btn btn-sm md:btn-md",
              @media_item.monitored && "btn-success",
              !@media_item.monitored && "btn-ghost"
            ]}
          >
            <.icon
              name={if @media_item.monitored, do: "hero-bookmark-solid", else: "hero-bookmark"}
              class="w-4 h-4 md:w-5 md:h-5"
            />
            <span class="hidden sm:inline">
              {if @media_item.monitored, do: "Monitored", else: "Not Monitored"}
            </span>
          </button>

          <button
            type="button"
            phx-click="refresh_metadata"
            class="btn btn-ghost btn-sm md:btn-md"
            title="Refresh metadata and episodes from metadata provider"
          >
            <.icon name="hero-arrow-path" class="w-4 h-4 md:w-5 md:h-5" />
            <span class="hidden sm:inline">Refresh</span>
          </button>

          <%= if @media_item.type == "tv_show" && has_media_files?(@media_item) do %>
            <button
              type="button"
              phx-click="rescan_series"
              class="btn btn-ghost btn-sm md:btn-md"
              title="Re-scan series: discover new files and refresh metadata for all episodes"
            >
              <.icon name="hero-folder-arrow-down" class="w-4 h-4 md:w-5 md:h-5" />
              <span class="hidden sm:inline">Re-scan</span>
            </button>
          <% end %>

          <%= if @media_item.type == "movie" && has_media_files?(@media_item) do %>
            <button
              type="button"
              phx-click="rescan_movie"
              class="btn btn-ghost btn-sm md:btn-md"
              title="Re-scan movie: discover new files and refresh metadata"
            >
              <.icon name="hero-folder-arrow-down" class="w-4 h-4 md:w-5 md:h-5" />
              <span class="hidden sm:inline">Re-scan</span>
            </button>
          <% end %>

          <%= if has_media_files?(@media_item) do %>
            <button
              type="button"
              phx-click="show_rename_modal"
              class="btn btn-ghost btn-sm md:btn-md"
              title="Rename files to follow naming convention"
            >
              <.icon name="hero-pencil-square" class="w-4 h-4 md:w-5 md:h-5" />
              <span class="hidden sm:inline">Rename</span>
            </button>
          <% end %>
        </div>

        <div class="divider my-2"></div>

        <%!-- Info Cards --%>
        <div class="space-y-2">
          <%!-- Quality Profile --%>
          <div class="dropdown dropdown-end w-full">
            <div
              tabindex="0"
              role="button"
              class="stat bg-base-200 rounded-box p-2 md:p-3 cursor-pointer hover:bg-base-300 transition-colors text-left w-full group"
              title="Click to change quality profile"
            >
              <div class="stat-title text-xs">Quality Profile</div>
              <div class="stat-value text-sm flex items-center gap-2">
                <%= if @media_item.quality_profile do %>
                  <span class="group-hover:text-primary transition-colors">
                    {@media_item.quality_profile.name}
                  </span>
                <% else %>
                  <span class="text-base-content/50 group-hover:text-primary transition-colors">
                    Not Set
                  </span>
                <% end %>
                <.icon
                  name="hero-chevron-down"
                  class="w-3 h-3 opacity-50 group-hover:opacity-100 transition-opacity"
                />
              </div>
            </div>
            <ul
              tabindex="0"
              class="dropdown-content z-[1] menu p-2 shadow-lg bg-base-100 rounded-box w-52 border border-base-300"
            >
              <li>
                <button
                  type="button"
                  phx-click="update_quality_profile"
                  phx-value-profile-id=""
                  class={[
                    "justify-between",
                    is_nil(@media_item.quality_profile_id) && "active"
                  ]}
                >
                  No Profile
                  <%= if is_nil(@media_item.quality_profile_id) do %>
                    <.icon name="hero-check" class="w-4 h-4" />
                  <% end %>
                </button>
              </li>
              <li :for={profile <- @quality_profiles}>
                <button
                  type="button"
                  phx-click="update_quality_profile"
                  phx-value-profile-id={profile.id}
                  class={[
                    "justify-between",
                    @media_item.quality_profile_id == profile.id && "active"
                  ]}
                >
                  {profile.name}
                  <%= if @media_item.quality_profile_id == profile.id do %>
                    <.icon name="hero-check" class="w-4 h-4" />
                  <% end %>
                </button>
              </li>
            </ul>
          </div>

          <%!-- Category --%>
          <div class="stat bg-base-200 rounded-box p-2 md:p-3">
            <div class="stat-title text-xs">Category</div>
            <div class="stat-value text-sm">
              <button
                type="button"
                phx-click="show_category_modal"
                class="group cursor-pointer"
                title="Click to change category"
              >
                <%= if @media_item.category do %>
                  <.category_badge
                    category={@media_item.category}
                    override={@media_item.category_override}
                    class="group-hover:ring-2 group-hover:ring-primary transition-all"
                  />
                <% else %>
                  <span class="badge badge-ghost group-hover:ring-2 group-hover:ring-primary transition-all">
                    {if @media_item.type == "movie", do: "Movie", else: "TV Show"}
                  </span>
                <% end %>
              </button>
            </div>
          </div>

          <%!-- Path --%>
          <%= if path = get_media_path(@media_item) do %>
            <div class="stat bg-base-200 rounded-box p-2 md:p-3">
              <div class="stat-title text-xs">Path</div>
              <div class="stat-value text-xs font-mono truncate" title={path}>
                {path}
              </div>
            </div>
          <% end %>
        </div>

        <div class="divider my-2"></div>

        <%!-- Delete action --%>
        <button
          type="button"
          phx-click="show_delete_confirm"
          class="btn btn-error btn-ghost btn-sm md:btn-md w-full justify-start"
        >
          <.icon name="hero-trash" class="w-4 h-4 md:w-5 md:h-5" />
          <span>Delete</span>
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Overview section with description, cast, and crew.
  """
  attr :media_item, :map, required: true

  def overview_section(assigns) do
    ~H"""
    <%!-- Overview --%>
    <div class="card bg-base-200 shadow-lg mb-4 md:mb-6">
      <div class="card-body p-4 md:p-6">
        <h2 class="card-title text-lg md:text-xl">Overview</h2>
        <p class="text-sm md:text-base text-base-content/80 leading-relaxed">
          {get_overview(@media_item)}
        </p>
      </div>
    </div>

    <%!-- Cast and Crew --%>
    <% cast = get_cast(@media_item)
    crew = get_crew(@media_item) %>
    <%= if cast != [] or crew != [] do %>
      <div class="card bg-base-200 shadow-lg mb-4 md:mb-6">
        <div class="card-body p-4 md:p-6">
          <h2 class="card-title text-lg md:text-xl mb-3 md:mb-4">Cast & Crew</h2>

          <%= if crew != [] do %>
            <div class="mb-6">
              <h3 class="text-sm font-semibold text-base-content/70 mb-3">Key Crew</h3>
              <div class="flex flex-wrap gap-3">
                <div :for={member <- crew} class="badge badge-lg badge-outline gap-2">
                  <span class="font-medium">{member.name}</span>
                  <span class="text-base-content/60">• {member.job}</span>
                </div>
              </div>
            </div>
          <% end %>

          <%= if cast != [] do %>
            <div>
              <h3 class="text-sm font-semibold text-base-content/70 mb-3">Cast</h3>
              <div class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6 gap-4">
                <div :for={actor <- cast} class="flex flex-col items-center text-center">
                  <div class="avatar mb-2">
                    <div class="w-20 h-20 rounded-full bg-base-300">
                      <%= if get_profile_image_url(actor.profile_path) do %>
                        <img
                          src={get_profile_image_url(actor.profile_path)}
                          alt={actor.name}
                          class="object-cover"
                        />
                      <% else %>
                        <div class="flex items-center justify-center h-full">
                          <.icon name="hero-user" class="w-10 h-10 text-base-content/30" />
                        </div>
                      <% end %>
                    </div>
                  </div>
                  <div class="text-sm font-medium line-clamp-2">{actor.name}</div>
                  <div class="text-xs text-base-content/60 line-clamp-2">
                    {actor.character}
                  </div>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  Episodes section for TV shows.
  """
  attr :media_item, :map, required: true
  attr :expanded_seasons, :map, required: true
  attr :expanded_episodes, :map, default: MapSet.new()
  attr :auto_searching_season, :any, default: nil
  attr :rescanning_season, :any, default: nil
  attr :auto_searching_episode, :any, default: nil
  attr :playback_enabled, :boolean, required: true

  def episodes_section(assigns) do
    ~H"""
    <%= if @media_item.type == "tv_show" && length(@media_item.episodes) > 0 do %>
      <div class="card bg-base-200 shadow-lg mb-4 md:mb-6">
        <div class="card-body p-4 md:p-6">
          <h2 class="card-title text-lg md:text-xl mb-3 md:mb-4">Episodes</h2>

          <% grouped_seasons = group_episodes_by_season(@media_item.episodes) %>
          <%= for {season_num, episodes} <- grouped_seasons do %>
            <div class="collapse collapse-arrow bg-base-100 mb-2">
              <input
                type="checkbox"
                checked={MapSet.member?(@expanded_seasons, season_num)}
                phx-click="toggle_season_expanded"
                phx-value-season-number={season_num}
              />
              <div class="collapse-title text-lg font-medium">
                Season {season_num}
                <span class="badge badge-ghost badge-sm ml-2">
                  {length(episodes)} episodes
                </span>
              </div>
              <div class="collapse-content">
                <%!-- Season-level actions - scrollable on mobile --%>
                <div class="flex gap-1 mb-4 justify-end overflow-x-auto pb-2">
                  <div
                    class="tooltip tooltip-bottom"
                    data-tip="Auto search season (prefers season pack)"
                  >
                    <button
                      type="button"
                      phx-click="auto_search_season"
                      phx-value-season-number={season_num}
                      class="btn btn-xs sm:btn-sm btn-primary"
                      disabled={@auto_searching_season == season_num}
                    >
                      <%= if @auto_searching_season == season_num do %>
                        <span class="loading loading-spinner loading-xs"></span>
                      <% else %>
                        <.icon name="hero-bolt" class="w-3 h-3 sm:w-4 sm:h-4" />
                      <% end %>
                    </button>
                  </div>
                  <div class="tooltip tooltip-bottom" data-tip="Manual search season">
                    <button
                      type="button"
                      phx-click="manual_search_season"
                      phx-value-season-number={season_num}
                      class="btn btn-xs sm:btn-sm btn-outline"
                    >
                      <.icon name="hero-magnifying-glass" class="w-3 h-3 sm:w-4 sm:h-4" />
                    </button>
                  </div>
                  <div
                    class="tooltip tooltip-bottom"
                    data-tip="Re-scan season: discover new files and refresh metadata"
                  >
                    <button
                      type="button"
                      phx-click="rescan_season"
                      phx-value-season-number={season_num}
                      class="btn btn-xs sm:btn-sm btn-ghost"
                      disabled={@rescanning_season == season_num}
                    >
                      <%= if @rescanning_season == season_num do %>
                        <span class="loading loading-spinner loading-xs"></span>
                      <% else %>
                        <.icon name="hero-arrow-path" class="w-3 h-3 sm:w-4 sm:h-4" />
                      <% end %>
                    </button>
                  </div>
                  <div class="tooltip tooltip-bottom" data-tip="Monitor all episodes">
                    <button
                      type="button"
                      phx-click="monitor_season"
                      phx-value-season-number={season_num}
                      class="btn btn-xs sm:btn-sm btn-ghost"
                    >
                      <.icon name="hero-bookmark-solid" class="w-3 h-3 sm:w-4 sm:h-4" />
                    </button>
                  </div>
                  <div class="tooltip tooltip-bottom" data-tip="Unmonitor all episodes">
                    <button
                      type="button"
                      phx-click="unmonitor_season"
                      phx-value-season-number={season_num}
                      class="btn btn-xs sm:btn-sm btn-ghost"
                    >
                      <.icon name="hero-bookmark" class="w-3 h-3 sm:w-4 sm:h-4" />
                    </button>
                  </div>
                </div>
                <div class="overflow-x-auto">
                  <table class="table table-sm">
                    <thead>
                      <tr>
                        <th class="w-16">#</th>
                        <th>Title</th>
                        <th class="hidden md:table-cell">Air Date</th>
                        <th class="hidden lg:table-cell">Quality</th>
                        <th>Status</th>
                        <th class="w-24">Actions</th>
                      </tr>
                    </thead>
                    <tbody>
                      <%= for episode <- Enum.sort_by(episodes, & &1.episode_number, :desc) do %>
                        <% has_files = length(episode.media_files) > 0
                        is_expanded = MapSet.member?(@expanded_episodes, episode.id) %>
                        <tr>
                          <td class="font-mono text-base-content/70">
                            <div
                              class={[
                                "flex items-center gap-1",
                                has_files && "cursor-pointer hover:text-primary"
                              ]}
                              phx-click={has_files && "toggle_episode_expanded"}
                              phx-value-episode-id={episode.id}
                              title={has_files && "Click to expand/collapse file details"}
                            >
                              <%= if has_files do %>
                                <.icon
                                  name={
                                    if is_expanded,
                                      do: "hero-chevron-down",
                                      else: "hero-chevron-right"
                                  }
                                  class="w-4 h-4 text-base-content/50"
                                />
                              <% else %>
                                <span class="w-4"></span>
                              <% end %>
                              {episode.episode_number}
                            </div>
                          </td>
                          <td>
                            <div
                              class={[
                                "font-medium",
                                has_files && "cursor-pointer hover:text-primary"
                              ]}
                              phx-click={has_files && "toggle_episode_expanded"}
                              phx-value-episode-id={episode.id}
                            >
                              {episode.title || "TBA"}
                            </div>
                          </td>
                          <td class="hidden md:table-cell text-sm">
                            {format_date(episode.air_date)}
                          </td>
                          <td class="hidden lg:table-cell">
                            <%= if quality = get_episode_quality_badge(episode) do %>
                              <span class="badge badge-primary badge-sm">{quality}</span>
                            <% else %>
                              <span class="text-base-content/50">—</span>
                            <% end %>
                          </td>
                          <td>
                            <% status = get_episode_status(episode) %>
                            <div
                              class="tooltip tooltip-left"
                              data-tip={episode_status_tooltip(episode)}
                            >
                              <span class={[
                                "badge badge-sm",
                                episode_status_color(status)
                              ]}>
                                <.icon name={episode_status_icon(status)} class="w-4 h-4" />
                              </span>
                            </div>
                          </td>
                          <td>
                            <div class="flex gap-0.5 sm:gap-1">
                              <%!-- Play button (if episode has media files) --%>
                              <%= if @playback_enabled && has_files do %>
                                <.link
                                  navigate={~p"/play/episode/#{episode.id}"}
                                  class="btn btn-success btn-xs btn-square"
                                  title="Play episode"
                                >
                                  <.icon name="hero-play-solid" class="w-3 h-3" />
                                </.link>
                              <% end %>
                              <button
                                type="button"
                                phx-click="auto_search_episode"
                                phx-value-episode-id={episode.id}
                                class="btn btn-primary btn-xs btn-square"
                                disabled={@auto_searching_episode == episode.id}
                                title="Auto search and download this episode"
                              >
                                <%= if @auto_searching_episode == episode.id do %>
                                  <span class="loading loading-spinner loading-xs"></span>
                                <% else %>
                                  <.icon name="hero-bolt" class="w-3 h-3" />
                                <% end %>
                              </button>
                              <button
                                type="button"
                                phx-click="search_episode"
                                phx-value-episode-id={episode.id}
                                class="btn btn-ghost btn-xs btn-square"
                                title="Manual search for episode"
                              >
                                <.icon name="hero-magnifying-glass" class="w-3 h-3" />
                              </button>
                              <button
                                type="button"
                                phx-click="toggle_episode_monitored"
                                phx-value-episode-id={episode.id}
                                class="btn btn-ghost btn-xs btn-square"
                                title={
                                  if episode.monitored,
                                    do: "Stop monitoring",
                                    else: "Start monitoring"
                                }
                              >
                                <.icon
                                  name={
                                    if episode.monitored,
                                      do: "hero-bookmark-solid",
                                      else: "hero-bookmark"
                                  }
                                  class="w-3 h-3"
                                />
                              </button>
                            </div>
                          </td>
                        </tr>
                        <%!-- Expanded file details row --%>
                        <%= if is_expanded && has_files do %>
                          <tr :for={file <- episode.media_files} class="bg-base-300/30">
                            <td colspan="6" class="py-2 pl-10">
                              <.episode_file_row
                                file={file}
                                episode={episode}
                                playback_enabled={@playback_enabled}
                              />
                            </td>
                          </tr>
                        <% end %>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  Renders a single media file row within an expanded episode.
  """
  attr :file, :map, required: true
  attr :episode, :map, required: true
  attr :playback_enabled, :boolean, required: true

  def episode_file_row(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-4 py-1">
      <%!-- File info --%>
      <div class="flex flex-col gap-1 min-w-0 flex-1">
        <%!-- Filename row --%>
        <div class="flex items-center gap-2">
          <.icon name="hero-document" class="w-4 h-4 text-base-content/50 flex-shrink-0" />
          <% absolute_path = Mydia.Library.MediaFile.absolute_path(@file) %>
          <span class="font-mono text-sm truncate" title={absolute_path}>
            {Path.basename(absolute_path)}
          </span>
        </div>
        <%!-- Technical details row --%>
        <div class="flex flex-wrap items-center gap-1.5 pl-6 text-xs">
          <span class="badge badge-primary badge-xs">{@file.resolution || "?"}</span>
          <%= if @file.codec do %>
            <span class="text-base-content/60" title={@file.codec}>
              {shorten_codec(@file.codec)}
            </span>
          <% end %>
          <%= if @file.audio_codec do %>
            <span class="text-base-content/60" title={@file.audio_codec}>
              {shorten_codec(@file.audio_codec)}
            </span>
          <% end %>
          <span class="text-base-content/60">
            {format_file_size(@file.size)}
          </span>
        </div>
      </div>
      <%!-- File actions --%>
      <div class="flex items-center gap-1 flex-shrink-0">
        <%= if @playback_enabled do %>
          <.link
            navigate={~p"/play/episode/#{@episode.id}?file_id=#{@file.id}"}
            class="btn btn-ghost btn-xs btn-square"
            title="Play this file"
          >
            <.icon name="hero-play-solid" class="w-4 h-4" />
          </.link>
        <% end %>
        <button
          type="button"
          phx-click="mark_file_preferred"
          phx-value-file-id={@file.id}
          class="btn btn-ghost btn-xs btn-square"
          title="Mark as preferred"
        >
          <.icon name="hero-star" class="w-4 h-4" />
        </button>
        <button
          type="button"
          phx-click="show_file_delete_confirm"
          phx-value-file-id={@file.id}
          class="btn btn-ghost btn-xs btn-square text-error hover:bg-error hover:text-error-content"
          title="Delete file"
        >
          <.icon name="hero-trash" class="w-4 h-4" />
        </button>
      </div>
    </div>
    """
  end

  # Shorten long codec names for display
  defp shorten_codec(nil), do: nil

  defp shorten_codec(codec) do
    codec
    |> String.replace(~r/\s*\([^)]*\)/, "")
    |> String.replace("Dolby Digital Plus", "DD+")
    |> String.replace("Dolby Digital", "DD")
    |> String.replace("DTS-HD MA", "DTS-MA")
    |> String.replace("TrueHD", "TrueHD")
  end

  @doc """
  Media files section showing all files for this media item.
  """
  attr :media_item, :map, required: true
  attr :refreshing_file_metadata, :boolean, required: true

  def media_files_section(assigns) do
    ~H"""
    <%= if length(@media_item.media_files) > 0 do %>
      <div class="card bg-base-200 shadow-lg mb-4 md:mb-6">
        <div class="card-body p-4 md:p-6">
          <h2 class="card-title text-lg md:text-xl mb-3 md:mb-4">Media Files</h2>
          <%!-- DaisyUI list component --%>
          <ul class="menu bg-base-100 rounded-box p-0">
            <li :for={file <- @media_item.media_files}>
              <div class="flex items-start justify-between gap-4 p-4 hover:bg-base-200 rounded-none transition-colors">
                <%!-- Left side: File info --%>
                <div class="flex-1 min-w-0 flex flex-col gap-2">
                  <%!-- File path --%>
                  <% absolute_path = Mydia.Library.MediaFile.absolute_path(file) %>
                  <p
                    class="text-sm font-mono text-base-content break-all leading-relaxed"
                    title={absolute_path}
                  >
                    {absolute_path}
                  </p>
                  <%!-- Technical details with quality badge --%>
                  <div class="flex flex-wrap gap-4 text-xs text-base-content/70 items-center">
                    <span class="badge badge-primary badge-sm">
                      {file.resolution || "Unknown"}
                    </span>
                    <div class="flex items-center gap-1.5">
                      <.icon name="hero-film" class="w-3.5 h-3.5" />
                      <span>{file.codec || "Unknown"}</span>
                    </div>
                    <div class="flex items-center gap-1.5">
                      <.icon name="hero-speaker-wave" class="w-3.5 h-3.5" />
                      <span>{file.audio_codec || "Unknown"}</span>
                    </div>
                    <div class="flex items-center gap-1.5">
                      <.icon name="hero-circle-stack" class="w-3.5 h-3.5" />
                      <span class="font-mono">{format_file_size(file.size)}</span>
                    </div>
                  </div>
                </div>
                <%!-- Right side: Icon-only action buttons --%>
                <div class="flex items-center gap-1 flex-shrink-0">
                  <button
                    type="button"
                    phx-click="show_file_details"
                    phx-value-file-id={file.id}
                    class="btn btn-ghost btn-sm btn-square"
                    aria-label="View file details"
                    title="View file details"
                  >
                    <.icon name="hero-information-circle" class="w-5 h-5" />
                  </button>
                  <button
                    type="button"
                    phx-click="mark_file_preferred"
                    phx-value-file-id={file.id}
                    class="btn btn-ghost btn-sm btn-square"
                    aria-label="Mark this file as preferred"
                    title="Mark as preferred"
                  >
                    <.icon name="hero-star" class="w-5 h-5" />
                  </button>
                  <button
                    type="button"
                    phx-click="show_file_delete_confirm"
                    phx-value-file-id={file.id}
                    class="btn btn-ghost btn-sm btn-square text-error hover:bg-error hover:text-error-content"
                    aria-label="Delete this file"
                    title="Delete file"
                  >
                    <.icon name="hero-trash" class="w-5 h-5" />
                  </button>
                </div>
              </div>
            </li>
          </ul>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  Timeline section showing history of events.
  """
  attr :timeline_events, :list, required: true

  def timeline_section(assigns) do
    ~H"""
    <%= if length(@timeline_events) > 0 do %>
      <div class="card bg-base-200 shadow-lg mb-4 md:mb-6">
        <div class="card-body p-4 md:p-6">
          <h2 class="card-title text-lg md:text-xl mb-3 md:mb-4">History</h2>
          <%!-- Horizontal scrollable timeline container --%>
          <div class="w-full overflow-x-auto scroll-smooth pb-4 -mx-4 px-4">
            <div class="flex gap-0 min-w-max relative">
              <%!-- Horizontal timeline line --%>
              <div class="absolute top-[32px] left-0 right-0 h-0.5 bg-base-300 z-0"></div>

              <%!-- Timeline events --%>
              <%= for {event, index} <- Enum.with_index(@timeline_events) do %>
                <div class="relative flex flex-col items-center z-10 min-w-[280px] md:min-w-[280px]">
                  <%!-- Time above timeline --%>
                  <time
                    class="text-xs text-base-content/60 mb-2 whitespace-nowrap"
                    title={format_absolute_time(event.timestamp)}
                  >
                    {format_relative_time(event.timestamp)}
                  </time>

                  <%!-- Timeline node and connector --%>
                  <div class="relative flex items-center justify-center">
                    <%!-- Icon node on timeline --%>
                    <div class="w-10 h-10 rounded-full bg-base-200 flex items-center justify-center border-2 border-base-300 z-20">
                      <.icon name={event.icon} class={"w-5 h-5 #{event.color}"} />
                    </div>
                  </div>

                  <%!-- Event card below timeline --%>
                  <div
                    class="card bg-base-100 shadow-md mt-4 w-64 md:w-64 hover:shadow-xl transition-shadow"
                    title={format_absolute_time(event.timestamp)}
                  >
                    <div class="card-body p-4">
                      <div class="font-bold text-sm mb-2">{event.title}</div>
                      <div class="text-sm text-base-content/80 mb-2 line-clamp-2">
                        {event.description}
                      </div>
                      <%= if event.metadata do %>
                        <div class="flex flex-wrap gap-1">
                          <%= if event.metadata[:quality] do %>
                            <span class="badge badge-primary badge-xs">
                              {format_download_quality(event.metadata.quality)}
                            </span>
                          <% end %>
                          <%= if event.metadata[:indexer] do %>
                            <span class="badge badge-outline badge-xs">
                              {event.metadata.indexer}
                            </span>
                          <% end %>
                          <%= if event.metadata[:resolution] do %>
                            <span class="badge badge-primary badge-xs">
                              {event.metadata.resolution}
                            </span>
                          <% end %>
                          <%= if event.metadata[:size] do %>
                            <span class="badge badge-ghost badge-xs">
                              {format_file_size(event.metadata.size)}
                            </span>
                          <% end %>
                          <%= if event.metadata[:error] do %>
                            <div class="text-xs text-error mt-1 line-clamp-2">
                              <.icon name="hero-exclamation-circle" class="w-3 h-3 inline" />
                              {event.metadata.error}
                            </div>
                          <% end %>
                        </div>
                      <% end %>
                    </div>
                  </div>

                  <%!-- Connecting line to next event --%>
                  <%= if index < length(@timeline_events) - 1 do %>
                    <div class={"absolute top-[32px] left-1/2 w-[280px] h-0.5 #{event.color} z-0"}>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  Subtitles section showing available and downloaded subtitles for media files.
  """
  attr :media_item, :map, required: true
  attr :subtitle_feature_enabled, :boolean, required: true
  attr :media_file_subtitles, :map, default: %{}

  def subtitles_section(assigns) do
    ~H"""
    <%= if @subtitle_feature_enabled && length(@media_item.media_files) > 0 do %>
      <div class="card bg-base-200 shadow-lg mb-4 md:mb-6">
        <div class="card-body p-4 md:p-6">
          <h2 class="card-title text-lg md:text-xl mb-3 md:mb-4">Subtitles</h2>

          <%!-- Media files with subtitle controls --%>
          <div class="space-y-4">
            <%= for media_file <- @media_item.media_files do %>
              <% file_subtitles = Map.get(@media_file_subtitles, media_file.id, []) %>
              <div class="card bg-base-100 shadow">
                <div class="card-body p-4">
                  <%!-- File info header --%>
                  <div class="flex items-start justify-between gap-4 mb-3">
                    <div class="flex-1 min-w-0">
                      <% absolute_path = Mydia.Library.MediaFile.absolute_path(media_file) %>
                      <p
                        class="text-sm font-mono text-base-content/80 break-all"
                        title={absolute_path}
                      >
                        {Path.basename(absolute_path)}
                      </p>
                      <div class="flex gap-2 mt-1">
                        <span class="badge badge-primary badge-xs">
                          {media_file.resolution || "Unknown"}
                        </span>
                        <span class="badge badge-ghost badge-xs">
                          {media_file.codec || "Unknown"}
                        </span>
                      </div>
                    </div>
                    <button
                      type="button"
                      phx-click="open_subtitle_search"
                      phx-value-media-file-id={media_file.id}
                      class="btn btn-primary btn-sm"
                    >
                      <.icon name="hero-magnifying-glass" class="w-4 h-4" /> Search
                    </button>
                  </div>

                  <%!-- Downloaded subtitles --%>
                  <%= if length(file_subtitles) > 0 do %>
                    <div class="divider my-2">Downloaded Subtitles</div>
                    <ul class="space-y-2">
                      <%= for subtitle <- file_subtitles do %>
                        <li class="flex items-center justify-between gap-2 p-2 bg-base-200 rounded">
                          <div class="flex items-center gap-2 flex-1">
                            <span class="badge badge-outline badge-sm">{subtitle.language}</span>
                            <span class="text-sm">{subtitle.format}</span>
                            <%= if subtitle.rating do %>
                              <div class="flex items-center gap-1">
                                <.icon name="hero-star-solid" class="w-3 h-3 text-warning" />
                                <span class="text-xs">{subtitle.rating}/10</span>
                              </div>
                            <% end %>
                          </div>
                          <button
                            type="button"
                            phx-click="delete_subtitle"
                            phx-value-subtitle-id={subtitle.id}
                            class="btn btn-ghost btn-xs btn-square text-error"
                            title="Delete subtitle"
                          >
                            <.icon name="hero-trash" class="w-4 h-4" />
                          </button>
                        </li>
                      <% end %>
                    </ul>
                  <% else %>
                    <p class="text-sm text-base-content/60 italic">
                      No subtitles downloaded yet
                    </p>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    <% end %>
    """
  end
end
