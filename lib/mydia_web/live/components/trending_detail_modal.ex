defmodule MydiaWeb.Live.Components.TrendingDetailModal do
  @moduledoc """
  A LiveComponent for displaying detailed information about trending movies/TV shows.

  Shows a rich modal with backdrop image, synopsis, cast, ratings, and trailers
  when clicking on trending items from the dashboard.

  ## Usage

      <.live_component
        module={MydiaWeb.Live.Components.TrendingDetailModal}
        id="trending-detail-modal"
        item={@selected_item}
        metadata={@selected_metadata}
        loading={@detail_loading}
        current_user={@current_user}
      />

  ## Events

  The component emits these events to the parent LiveView:

  - `close_details` - When user closes the modal
  - `add_to_library` - When user clicks "Add to Library" (with tmdb_id and media_type params)
  """
  use MydiaWeb, :live_component

  alias Mydia.Metadata.Structs.Video

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="modal modal-open" id={@id} phx-window-keydown="close_details" phx-key="Escape">
        <div class="modal-backdrop bg-black/70" phx-click="close_details"></div>
        <div class="modal-box max-w-5xl w-11/12 max-h-[90vh] p-0 overflow-hidden">
          <%!-- Header with backdrop --%>
          <div class="relative h-48 md:h-64 bg-base-300">
            <%= if backdrop_path(@item, @metadata) do %>
              <img
                src={"https://image.tmdb.org/t/p/w1280#{backdrop_path(@item, @metadata)}"}
                alt=""
                class="w-full h-full object-cover"
              />
              <div class="absolute inset-0 bg-gradient-to-t from-base-100 via-base-100/50 to-transparent">
              </div>
            <% else %>
              <div class="w-full h-full bg-gradient-to-br from-primary/20 to-secondary/20"></div>
            <% end %>

            <%!-- Close button --%>
            <button
              phx-click="close_details"
              class="btn btn-circle btn-ghost btn-sm absolute top-4 right-4 bg-base-100/50 hover:bg-base-100"
            >
              <.icon name="hero-x-mark" class="w-5 h-5" />
            </button>

            <%!-- Title overlay --%>
            <div class="absolute bottom-0 left-0 right-0 p-4 md:p-6">
              <div class="flex items-end gap-4">
                <%= if poster_path(@item, @metadata) do %>
                  <img
                    src={"https://image.tmdb.org/t/p/w185#{poster_path(@item, @metadata)}"}
                    alt={title(@item, @metadata)}
                    class="w-20 md:w-28 rounded-lg shadow-xl hidden sm:block"
                  />
                <% end %>
                <div class="flex-1">
                  <h2 class="text-2xl md:text-3xl font-bold text-white drop-shadow-lg">
                    {title(@item, @metadata)}
                  </h2>
                  <div class="flex flex-wrap items-center gap-2 mt-1">
                    <%= if year(@item, @metadata) do %>
                      <span class="badge badge-ghost">{year(@item, @metadata)}</span>
                    <% end %>
                    <%= if vote_average(@item, @metadata) do %>
                      <span class="badge badge-warning gap-1">
                        <.icon name="hero-star-solid" class="w-3 h-3" />
                        {Float.round(vote_average(@item, @metadata), 1)}
                      </span>
                    <% end %>
                    <%= if runtime(@metadata) do %>
                      <span class="badge badge-ghost">{format_runtime(runtime(@metadata))}</span>
                    <% end %>
                    <%= if genres(@metadata) != [] do %>
                      <span class="text-white/40">•</span>
                    <% end %>
                    <%= for genre <- genres(@metadata) do %>
                      <span class="badge badge-outline">{genre}</span>
                    <% end %>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <%!-- Body content --%>
          <div class="p-4 md:p-6 overflow-y-auto max-h-[calc(90vh-16rem)]">
            <%= if @loading do %>
              <div class="flex items-center justify-center py-12">
                <span class="loading loading-spinner loading-lg"></span>
                <span class="ml-3 text-base-content/70">Loading details...</span>
              </div>
            <% else %>
              <div class="space-y-6">
                <%!-- Trailer --%>
                <%= if first_trailer(@metadata) do %>
                  <div>
                    <h3 class="text-lg font-semibold mb-3">Trailer</h3>
                    <div class="aspect-video rounded-lg overflow-hidden bg-base-300">
                      <iframe
                        src={Video.youtube_embed_url(first_trailer(@metadata)) <> "?rel=0&modestbranding=1"}
                        title="Trailer"
                        class="w-full h-full"
                        allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
                        allowfullscreen
                      >
                      </iframe>
                    </div>
                  </div>
                <% end %>

                <%!-- Synopsis --%>
                <%= if overview(@item, @metadata) do %>
                  <div>
                    <h3 class="text-lg font-semibold mb-2">Synopsis</h3>
                    <p class="text-base-content/80 leading-relaxed">{overview(@item, @metadata)}</p>
                  </div>
                <% end %>

                <%!-- Cast --%>
                <%= if cast(@metadata) != [] do %>
                  <div>
                    <h3 class="text-lg font-semibold mb-3">Cast</h3>
                    <div class="grid grid-cols-3 sm:grid-cols-4 md:grid-cols-6 gap-3">
                      <%= for member <- Enum.take(cast(@metadata), 6) do %>
                        <div class="text-center">
                          <%= if member.profile_path do %>
                            <img
                              src={"https://image.tmdb.org/t/p/w185#{member.profile_path}"}
                              alt={member.name}
                              class="w-16 h-16 md:w-20 md:h-20 rounded-full object-cover mx-auto mb-2"
                            />
                          <% else %>
                            <div class="w-16 h-16 md:w-20 md:h-20 rounded-full bg-base-300 flex items-center justify-center mx-auto mb-2">
                              <.icon name="hero-user" class="w-8 h-8 text-base-content/30" />
                            </div>
                          <% end %>
                          <p class="text-sm font-medium line-clamp-1">{member.name}</p>
                          <%= if member.character do %>
                            <p class="text-xs text-base-content/60 line-clamp-1">
                              {member.character}
                            </p>
                          <% end %>
                        </div>
                      <% end %>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>

          <%!-- Footer actions --%>
          <div class="p-4 md:p-6 border-t border-base-300 bg-base-100 flex justify-end gap-2">
            <button class="btn btn-ghost" phx-click="close_details">
              Close
            </button>
            <%= if not in_library?(@item) do %>
              <%= if @current_user && @current_user.role == "guest" do %>
                <.link
                  navigate={request_path(@item)}
                  class="btn btn-primary"
                >
                  <.icon name="hero-paper-airplane" class="w-4 h-4" /> Request
                </.link>
              <% else %>
                <button
                  phx-click="add_to_library"
                  phx-value-tmdb_id={@item.provider_id}
                  phx-value-media_type={media_type_string(@item)}
                  class="btn btn-primary"
                >
                  <.icon name="hero-plus" class="w-4 h-4" /> Add to Library
                </button>
              <% end %>
            <% else %>
              <.link navigate={library_path(@item)} class="btn btn-ghost">
                <.icon name="hero-arrow-right" class="w-4 h-4" /> Go to {media_type_label(@item)}
              </.link>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:loading, fn -> false end)
     |> assign_new(:metadata, fn -> nil end)}
  end

  # Helper functions for accessing data from either SearchResult (item) or MediaMetadata

  defp title(item, nil), do: item.title
  defp title(_item, metadata), do: metadata.title

  defp year(item, nil), do: item.year
  defp year(_item, metadata), do: metadata.year

  defp poster_path(item, nil), do: item.poster_path
  defp poster_path(_item, metadata), do: metadata.poster_path

  defp backdrop_path(item, nil), do: item.backdrop_path
  defp backdrop_path(_item, metadata), do: metadata.backdrop_path

  defp overview(item, nil), do: item.overview
  defp overview(_item, metadata), do: metadata.overview

  defp vote_average(item, nil), do: item.vote_average
  defp vote_average(_item, metadata), do: metadata.vote_average

  defp runtime(nil), do: nil
  defp runtime(metadata), do: metadata.runtime

  defp genres(nil), do: []
  defp genres(metadata), do: metadata.genres || []

  defp cast(nil), do: []
  defp cast(metadata), do: metadata.cast || []

  defp first_trailer(nil), do: nil

  defp first_trailer(metadata) do
    case metadata.videos do
      [video | _] -> video
      _ -> nil
    end
  end

  defp in_library?(item), do: Map.get(item, :in_library, false)

  defp media_type_string(item) do
    case item.media_type do
      :movie -> "movie"
      :tv_show -> "tv_show"
      _ -> "movie"
    end
  end

  defp media_type_label(item) do
    case item.media_type do
      :movie -> "Movie"
      :tv_show -> "Show"
      _ -> "Movie"
    end
  end

  defp request_path(item) do
    case item.media_type do
      :movie -> "/request/movie?tmdb_id=#{item.provider_id}"
      :tv_show -> "/request/series?tmdb_id=#{item.provider_id}"
      _ -> "/request/movie?tmdb_id=#{item.provider_id}"
    end
  end

  defp library_path(item) do
    case item.media_type do
      :movie -> "/movies/#{item.id}"
      :tv_show -> "/tv/#{item.id}"
      _ -> "/movies/#{item.id}"
    end
  end

  defp format_runtime(nil), do: nil

  defp format_runtime(minutes) when is_integer(minutes) and minutes > 0 do
    hours = div(minutes, 60)
    mins = rem(minutes, 60)

    cond do
      hours > 0 and mins > 0 -> "#{hours}h #{mins}m"
      hours > 0 -> "#{hours}h"
      true -> "#{mins}m"
    end
  end

  defp format_runtime(_), do: nil
end
