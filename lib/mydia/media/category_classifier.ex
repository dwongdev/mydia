defmodule Mydia.Media.CategoryClassifier do
  @moduledoc """
  Classifies media items into categories based on metadata signals.

  This module implements automatic media categorization similar to Sonarr/Radarr,
  using metadata from TMDB/TVDB to determine whether content is:
  - Regular movies/TV shows
  - Anime (Japanese animation)
  - Cartoons (Western animation)

  ## Classification Logic

  The classifier uses the following decision tree:

  1. For movies (`type == "movie"`):
     - If animated? AND japanese_origin? → `:anime_movie`
     - If animated? AND NOT japanese_origin? → `:cartoon_movie`
     - Otherwise → `:movie`

  2. For TV shows (`type == "tv_show"`):
     - If animated? AND japanese_origin? → `:anime_series`
     - If animated? AND NOT japanese_origin? → `:cartoon_series`
     - Otherwise → `:tv_show`

  ## Detection Signals

  **Animation detection:**
  - Genre contains "Animation" (TMDB genre)
  - Genre contains "Anime" (TVDB native genre)

  **Japanese origin detection:**
  - `origin_country` includes "JP"
  - `original_language` == "ja"
  - Genre contains "Anime" (explicit signal from TVDB)
  """

  alias Mydia.Media.{MediaCategory, MediaItem}
  alias Mydia.Metadata.Structs.MediaMetadata

  @animation_genres ["Animation", "Anime"]
  @anime_genre "Anime"
  @japan_country_code "JP"
  @japanese_language_code "ja"

  @doc """
  Classifies a media item based on its metadata.

  Returns one of the MediaCategory types based on the item's type and metadata signals.

  ## Examples

      iex> item = %MediaItem{type: "movie", metadata: %MediaMetadata{genres: ["Animation"], origin_country: ["JP"]}}
      iex> CategoryClassifier.classify(item)
      :anime_movie

      iex> item = %MediaItem{type: "tv_show", metadata: %MediaMetadata{genres: ["Drama"]}}
      iex> CategoryClassifier.classify(item)
      :tv_show
  """
  @spec classify(MediaItem.t()) :: MediaCategory.t()
  def classify(%MediaItem{type: "movie", metadata: metadata}) do
    classify_movie(metadata)
  end

  def classify(%MediaItem{type: "tv_show", metadata: metadata}) do
    classify_series(metadata)
  end

  def classify(%MediaItem{type: type}) do
    case type do
      "movie" -> :movie
      "tv_show" -> :tv_show
      _ -> :movie
    end
  end

  @doc """
  Classifies based on raw metadata (without a MediaItem wrapper).

  Useful when you have metadata but not a full MediaItem struct.

  ## Examples

      iex> CategoryClassifier.classify_from_metadata(:movie, %MediaMetadata{genres: ["Animation"], origin_country: ["JP"]})
      :anime_movie
  """
  @spec classify_from_metadata(atom(), MediaMetadata.t() | map() | nil) :: MediaCategory.t()
  def classify_from_metadata(:movie, metadata), do: classify_movie(metadata)
  def classify_from_metadata(:tv_show, metadata), do: classify_series(metadata)
  def classify_from_metadata(_, _), do: :movie

  @doc """
  Checks if metadata indicates animation content.

  Returns true if any of the genres contain "Animation" or "Anime".

  ## Examples

      iex> CategoryClassifier.animated?(%MediaMetadata{genres: ["Animation", "Comedy"]})
      true

      iex> CategoryClassifier.animated?(%MediaMetadata{genres: ["Drama"]})
      false
  """
  @spec animated?(MediaMetadata.t() | map() | nil) :: boolean()
  def animated?(nil), do: false

  def animated?(%MediaMetadata{genres: genres}) when is_list(genres) do
    genres_contain_animation?(genres)
  end

  def animated?(%{genres: genres}) when is_list(genres) do
    genres_contain_animation?(genres)
  end

  def animated?(_), do: false

  @doc """
  Checks if metadata indicates Japanese origin (anime).

  Returns true if any of these conditions are met:
  - `origin_country` includes "JP"
  - `original_language` is "ja"
  - Genre contains "Anime" (explicit signal)

  ## Examples

      iex> CategoryClassifier.japanese_origin?(%MediaMetadata{origin_country: ["JP"]})
      true

      iex> CategoryClassifier.japanese_origin?(%MediaMetadata{original_language: "ja"})
      true

      iex> CategoryClassifier.japanese_origin?(%MediaMetadata{genres: ["Anime"]})
      true

      iex> CategoryClassifier.japanese_origin?(%MediaMetadata{origin_country: ["US"]})
      false
  """
  @spec japanese_origin?(MediaMetadata.t() | map() | nil) :: boolean()
  def japanese_origin?(nil), do: false

  def japanese_origin?(%MediaMetadata{} = metadata) do
    check_japanese_origin(
      metadata.origin_country,
      metadata.original_language,
      metadata.genres
    )
  end

  def japanese_origin?(%{} = metadata) do
    check_japanese_origin(
      Map.get(metadata, :origin_country),
      Map.get(metadata, :original_language),
      Map.get(metadata, :genres)
    )
  end

  def japanese_origin?(_), do: false

  @doc """
  Checks if the genre list explicitly contains "Anime".

  This is useful for detecting anime content from TVDB which has a native "Anime" genre.

  ## Examples

      iex> CategoryClassifier.has_anime_genre?(%MediaMetadata{genres: ["Anime", "Action"]})
      true

      iex> CategoryClassifier.has_anime_genre?(%MediaMetadata{genres: ["Animation"]})
      false
  """
  @spec has_anime_genre?(MediaMetadata.t() | map() | nil) :: boolean()
  def has_anime_genre?(nil), do: false

  def has_anime_genre?(%MediaMetadata{genres: genres}) when is_list(genres) do
    @anime_genre in genres
  end

  def has_anime_genre?(%{genres: genres}) when is_list(genres) do
    @anime_genre in genres
  end

  def has_anime_genre?(_), do: false

  # Private helpers

  defp classify_movie(metadata) do
    cond do
      animated?(metadata) && japanese_origin?(metadata) -> :anime_movie
      animated?(metadata) -> :cartoon_movie
      true -> :movie
    end
  end

  defp classify_series(metadata) do
    cond do
      animated?(metadata) && japanese_origin?(metadata) -> :anime_series
      animated?(metadata) -> :cartoon_series
      true -> :tv_show
    end
  end

  defp genres_contain_animation?(genres) do
    Enum.any?(genres, fn genre ->
      genre in @animation_genres
    end)
  end

  defp check_japanese_origin(origin_country, original_language, genres) do
    country_is_japan?(origin_country) ||
      language_is_japanese?(original_language) ||
      genre_is_anime?(genres)
  end

  defp country_is_japan?(nil), do: false
  defp country_is_japan?(countries) when is_list(countries), do: @japan_country_code in countries
  defp country_is_japan?(_), do: false

  defp language_is_japanese?(nil), do: false
  defp language_is_japanese?(language), do: language == @japanese_language_code

  defp genre_is_anime?(nil), do: false
  defp genre_is_anime?(genres) when is_list(genres), do: @anime_genre in genres
  defp genre_is_anime?(_), do: false
end
