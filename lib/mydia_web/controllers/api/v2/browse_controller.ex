defmodule MydiaWeb.Api.V2.BrowseController do
  @moduledoc """
  REST API controller for browsing media content.

  Provides v2 endpoints for native player clients to browse and discover
  movies and TV shows with pagination and filtering support.
  """

  use MydiaWeb, :controller

  alias Mydia.{Media, Playback, Repo}
  alias Mydia.Auth.Guardian
  alias Mydia.Media.MediaItem
  import Ecto.Query
  require Logger

  @default_per_page 20
  @max_per_page 100

  @doc """
  Lists movies with pagination and filtering.

  GET /api/v2/browse/movies

  Query params:
    - page: Page number (default: 1)
    - per_page: Items per page (default: 20, max: 100)
    - sort: Sort field (title, year, added) (default: title)
    - order: Sort order (asc, desc) (default: asc)
    - filter[genre]: Filter by genre name
    - filter[year]: Filter by release year

  Returns:
    - 200: Paginated movie list with poster URLs and watch progress
  """
  def list_movies(conn, params) do
    current_user = Guardian.Plug.current_resource(conn)
    pagination_opts = parse_pagination_params(params)
    filter_opts = parse_movie_filters(params)

    query =
      MediaItem
      |> where([m], m.type == "movie")
      |> apply_movie_filters(filter_opts)
      |> apply_sort(pagination_opts[:sort], pagination_opts[:order])
      |> preload([:media_files, :playback_progress])

    # Get total count for pagination metadata
    total_count = Repo.aggregate(query, :count)

    # Apply pagination
    offset = (pagination_opts[:page] - 1) * pagination_opts[:per_page]

    movies =
      query
      |> limit(^pagination_opts[:per_page])
      |> offset(^offset)
      |> Repo.all()

    # Load progress for current user
    movies_with_progress = attach_movie_progress(movies, current_user.id)

    json(conn, %{
      data: Enum.map(movies_with_progress, &serialize_movie_list_item/1),
      pagination: %{
        page: pagination_opts[:page],
        per_page: pagination_opts[:per_page],
        total: total_count,
        total_pages: ceil(total_count / pagination_opts[:per_page])
      }
    })
  end

  @doc """
  Gets detailed information about a specific movie.

  GET /api/v2/browse/movies/:id

  Returns:
    - 200: Full movie details with available files and metadata
    - 404: Movie not found
  """
  def show_movie(conn, %{"id" => id}) do
    current_user = Guardian.Plug.current_resource(conn)

    case Media.get_media_item!(id, preload: [:media_files]) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Movie not found"})

      media_item ->
        if media_item.type != "movie" do
          conn
          |> put_status(:not_found)
          |> json(%{error: "Media item is not a movie"})
        else
          progress = Playback.get_progress(current_user.id, media_item_id: id)

          json(conn, %{
            data: serialize_movie_detail(media_item, progress)
          })
        end
    end
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{error: "Movie not found"})
  end

  @doc """
  Lists TV shows with pagination and filtering.

  GET /api/v2/browse/tv

  Query params:
    - page: Page number (default: 1)
    - per_page: Items per page (default: 20, max: 100)
    - sort: Sort field (title, year, added) (default: title)
    - order: Sort order (asc, desc) (default: asc)
    - filter[genre]: Filter by genre name
    - filter[year]: Filter by first air year

  Returns:
    - 200: Paginated TV show list
  """
  def list_tv_shows(conn, params) do
    current_user = Guardian.Plug.current_resource(conn)
    pagination_opts = parse_pagination_params(params)
    filter_opts = parse_tv_filters(params)

    query =
      MediaItem
      |> where([m], m.type == "tv_show")
      |> apply_tv_filters(filter_opts)
      |> apply_sort(pagination_opts[:sort], pagination_opts[:order])
      |> preload(:episodes)

    # Get total count for pagination metadata
    total_count = Repo.aggregate(query, :count)

    # Apply pagination
    offset = (pagination_opts[:page] - 1) * pagination_opts[:per_page]

    tv_shows =
      query
      |> limit(^pagination_opts[:per_page])
      |> offset(^offset)
      |> Repo.all()

    # Attach progress for current user
    tv_shows_with_progress = attach_tv_show_progress(tv_shows, current_user.id)

    json(conn, %{
      data: Enum.map(tv_shows_with_progress, &serialize_tv_show_list_item/1),
      pagination: %{
        page: pagination_opts[:page],
        per_page: pagination_opts[:per_page],
        total: total_count,
        total_pages: ceil(total_count / pagination_opts[:per_page])
      }
    })
  end

  @doc """
  Gets detailed information about a specific TV show.

  GET /api/v2/browse/tv/:id

  Returns:
    - 200: TV show details with seasons summary
    - 404: TV show not found
  """
  def show_tv_show(conn, %{"id" => id}) do
    current_user = Guardian.Plug.current_resource(conn)

    case Media.get_media_item!(id, preload: [:episodes]) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "TV show not found"})

      media_item ->
        if media_item.type != "tv_show" do
          conn
          |> put_status(:not_found)
          |> json(%{error: "Media item is not a TV show"})
        else
          # Get progress for all episodes
          episode_ids = Enum.map(media_item.episodes, & &1.id)

          progress_map =
            if Enum.empty?(episode_ids) do
              %{}
            else
              from(p in Playback.Progress,
                where: p.user_id == ^current_user.id and p.episode_id in ^episode_ids,
                select: {p.episode_id, p}
              )
              |> Repo.all()
              |> Map.new()
            end

          json(conn, %{
            data: serialize_tv_show_detail(media_item, progress_map)
          })
        end
    end
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{error: "TV show not found"})
  end

  @doc """
  Lists episodes for a specific season of a TV show.

  GET /api/v2/browse/tv/:id/seasons/:season

  Returns:
    - 200: Episode list with playback progress
    - 404: TV show not found or season not found
  """
  def list_season_episodes(conn, %{"id" => id, "season" => season_number_str}) do
    current_user = Guardian.Plug.current_resource(conn)

    case Integer.parse(season_number_str) do
      {season_number, ""} ->
        case Media.get_media_item!(id) do
          nil ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "TV show not found"})

          media_item ->
            if media_item.type != "tv_show" do
              conn
              |> put_status(:not_found)
              |> json(%{error: "Media item is not a TV show"})
            else
              episodes =
                Media.list_episodes(id, season: season_number, preload: [:media_files])

              if Enum.empty?(episodes) do
                conn
                |> put_status(:not_found)
                |> json(%{error: "Season not found"})
              else
                # Get progress for episodes
                episode_ids = Enum.map(episodes, & &1.id)

                progress_map =
                  from(p in Playback.Progress,
                    where: p.user_id == ^current_user.id and p.episode_id in ^episode_ids,
                    select: {p.episode_id, p}
                  )
                  |> Repo.all()
                  |> Map.new()

                json(conn, %{
                  data: %{
                    media_item_id: id,
                    season_number: season_number,
                    episodes: Enum.map(episodes, &serialize_episode(elem(&1, 0), progress_map))
                  }
                })
              end
            end
        end

      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid season number"})
    end
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{error: "TV show not found"})
  end

  ## Private Functions

  defp parse_pagination_params(params) do
    page = parse_integer(params["page"], 1)
    per_page = parse_integer(params["per_page"], @default_per_page)
    per_page = min(per_page, @max_per_page)

    sort = parse_sort_field(params["sort"])
    order = parse_sort_order(params["order"])

    %{
      page: max(page, 1),
      per_page: max(per_page, 1),
      sort: sort,
      order: order
    }
  end

  defp parse_integer(nil, default), do: default

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp parse_integer(value, _default) when is_integer(value), do: value
  defp parse_integer(_, default), do: default

  defp parse_sort_field(nil), do: :title
  defp parse_sort_field("title"), do: :title
  defp parse_sort_field("year"), do: :year
  defp parse_sort_field("added"), do: :inserted_at
  defp parse_sort_field(_), do: :title

  defp parse_sort_order(nil), do: :asc
  defp parse_sort_order("asc"), do: :asc
  defp parse_sort_order("desc"), do: :desc
  defp parse_sort_order(_), do: :asc

  defp parse_movie_filters(params) do
    filter = params["filter"] || %{}

    %{
      genre: filter["genre"],
      year: parse_integer(filter["year"], nil)
    }
  end

  defp parse_tv_filters(params) do
    filter = params["filter"] || %{}

    %{
      genre: filter["genre"],
      year: parse_integer(filter["year"], nil)
    }
  end

  defp apply_movie_filters(query, opts) do
    query
    |> filter_by_genre(opts[:genre])
    |> filter_by_year(opts[:year])
  end

  defp apply_tv_filters(query, opts) do
    query
    |> filter_by_genre(opts[:genre])
    |> filter_by_year(opts[:year])
  end

  defp filter_by_genre(query, nil), do: query

  defp filter_by_genre(query, genre) when is_binary(genre) do
    where(query, [m], fragment("? LIKE ?", m.genres, ^"%#{genre}%"))
  end

  defp filter_by_year(query, nil), do: query
  defp filter_by_year(query, year), do: where(query, [m], m.year == ^year)

  defp apply_sort(query, :title, order) do
    order_by(query, [m], [{^order, m.title}])
  end

  defp apply_sort(query, :year, order) do
    order_by(query, [m], [{^order, m.year}])
  end

  defp apply_sort(query, :inserted_at, order) do
    order_by(query, [m], [{^order, m.inserted_at}])
  end

  defp attach_movie_progress(movies, user_id) do
    movie_ids = Enum.map(movies, & &1.id)

    progress_map =
      if Enum.empty?(movie_ids) do
        %{}
      else
        from(p in Playback.Progress,
          where: p.user_id == ^user_id and p.media_item_id in ^movie_ids,
          select: {p.media_item_id, p}
        )
        |> Repo.all()
        |> Map.new()
      end

    Enum.map(movies, fn movie ->
      {movie, Map.get(progress_map, movie.id)}
    end)
  end

  defp attach_tv_show_progress(tv_shows, user_id) do
    # For TV shows, get all episode IDs across all shows
    all_episode_ids =
      tv_shows
      |> Enum.flat_map(fn show -> Enum.map(show.episodes, & &1.id) end)

    progress_map =
      if Enum.empty?(all_episode_ids) do
        %{}
      else
        from(p in Playback.Progress,
          where: p.user_id == ^user_id and p.episode_id in ^all_episode_ids,
          select: {p.episode_id, p}
        )
        |> Repo.all()
        |> Map.new()
      end

    Enum.map(tv_shows, fn show ->
      {show, progress_map}
    end)
  end

  defp serialize_movie_list_item({movie, progress}) do
    %{
      id: movie.id,
      title: movie.title,
      year: movie.year,
      poster_url: get_poster_url(movie),
      backdrop_url: get_backdrop_url(movie),
      overview: movie.overview,
      runtime: get_runtime(movie),
      genres: movie.genres || [],
      progress: serialize_progress(progress)
    }
  end

  defp serialize_movie_detail(movie, progress) do
    %{
      id: movie.id,
      title: movie.title,
      original_title: movie.original_title,
      year: movie.year,
      poster_url: get_poster_url(movie),
      backdrop_url: get_backdrop_url(movie),
      overview: movie.overview,
      runtime: get_runtime(movie),
      genres: movie.genres || [],
      tmdb_id: movie.tmdb_id,
      imdb_id: movie.imdb_id,
      status: get_status(movie),
      files: Enum.map(movie.media_files, &serialize_media_file/1),
      progress: serialize_progress(progress)
    }
  end

  defp serialize_tv_show_list_item({show, progress_map}) do
    # Calculate show-level progress
    total_episodes = length(show.episodes)

    watched_count =
      Enum.count(show.episodes, fn ep ->
        case Map.get(progress_map, ep.id) do
          %Playback.Progress{watched: true} -> true
          _ -> false
        end
      end)

    %{
      id: show.id,
      title: show.title,
      year: show.year,
      poster_url: get_poster_url(show),
      backdrop_url: get_backdrop_url(show),
      overview: show.overview,
      genres: show.genres || [],
      total_seasons: count_seasons(show.episodes),
      total_episodes: total_episodes,
      watched_episodes: watched_count
    }
  end

  defp serialize_tv_show_detail(show, progress_map) do
    seasons_summary = build_seasons_summary(show.episodes, progress_map)

    %{
      id: show.id,
      title: show.title,
      original_title: show.original_title,
      year: show.year,
      poster_url: get_poster_url(show),
      backdrop_url: get_backdrop_url(show),
      overview: show.overview,
      genres: show.genres || [],
      tmdb_id: show.tmdb_id,
      imdb_id: show.imdb_id,
      status: get_status(show),
      seasons: seasons_summary
    }
  end

  defp serialize_episode(episode, progress_map) do
    progress = Map.get(progress_map, episode.id)

    %{
      id: episode.id,
      season_number: episode.season_number,
      episode_number: episode.episode_number,
      title: episode.title,
      overview: get_episode_overview(episode),
      air_date: episode.air_date,
      still_url: get_episode_still_url(episode),
      files: Enum.map(episode.media_files, &serialize_media_file/1),
      progress: serialize_progress(progress)
    }
  end

  defp serialize_media_file(file) do
    %{
      id: file.id,
      resolution: file.resolution,
      codec: file.codec,
      hdr_format: file.hdr_format,
      audio_codec: file.audio_codec,
      size: file.size,
      bitrate: file.bitrate
    }
  end

  defp serialize_progress(nil) do
    %{
      position_seconds: 0,
      duration_seconds: 0,
      completion_percentage: 0.0,
      watched: false,
      last_watched_at: nil
    }
  end

  defp serialize_progress(progress) do
    %{
      position_seconds: progress.position_seconds,
      duration_seconds: progress.duration_seconds,
      completion_percentage: progress.completion_percentage,
      watched: progress.watched,
      last_watched_at: progress.last_watched_at
    }
  end

  defp build_seasons_summary(episodes, progress_map) do
    episodes
    |> Enum.group_by(& &1.season_number)
    |> Enum.map(fn {season_number, season_episodes} ->
      total = length(season_episodes)

      watched =
        Enum.count(season_episodes, fn ep ->
          case Map.get(progress_map, ep.id) do
            %Playback.Progress{watched: true} -> true
            _ -> false
          end
        end)

      %{
        season_number: season_number,
        episode_count: total,
        watched_count: watched
      }
    end)
    |> Enum.sort_by(& &1.season_number)
  end

  defp count_seasons(episodes) do
    episodes
    |> Enum.map(& &1.season_number)
    |> Enum.uniq()
    |> length()
  end

  defp get_poster_url(media_item) do
    case media_item.metadata do
      %{"poster_path" => path} when is_binary(path) -> path
      _ -> media_item.poster_url
    end
  end

  defp get_backdrop_url(media_item) do
    case media_item.metadata do
      %{"backdrop_path" => path} when is_binary(path) -> path
      _ -> media_item.backdrop_url
    end
  end

  defp get_runtime(media_item) do
    case media_item.metadata do
      %{"runtime" => runtime} when is_integer(runtime) -> runtime
      _ -> media_item.runtime
    end
  end

  defp get_status(media_item) do
    case media_item.metadata do
      %{"status" => status} when is_binary(status) -> status
      _ -> media_item.status
    end
  end

  defp get_episode_overview(episode) do
    case episode.metadata do
      %{"overview" => overview} when is_binary(overview) -> overview
      _ -> nil
    end
  end

  defp get_episode_still_url(episode) do
    case episode.metadata do
      %{"still_path" => path} when is_binary(path) -> path
      _ -> nil
    end
  end
end
