defmodule Mydia.Media.MediaCategory do
  @moduledoc """
  Defines media categories for automatic classification of content.

  Categories are used to organize media into specific types based on metadata
  signals like genres, origin country, and original language. This enables
  automatic routing of media to appropriate library paths.

  ## Categories

  - `:movie` - Standard live-action films
  - `:anime_movie` - Japanese animated films
  - `:cartoon_movie` - Non-Japanese animated films (Western animation)
  - `:tv_show` - Standard live-action TV series
  - `:anime_series` - Japanese animated TV series
  - `:cartoon_series` - Non-Japanese animated TV series (Western animation)
  """

  @type t ::
          :movie
          | :anime_movie
          | :cartoon_movie
          | :tv_show
          | :anime_series
          | :cartoon_series

  @categories [
    :movie,
    :anime_movie,
    :cartoon_movie,
    :tv_show,
    :anime_series,
    :cartoon_series
  ]

  @doc """
  Returns all valid media categories.

  ## Examples

      iex> MediaCategory.all()
      [:movie, :anime_movie, :cartoon_movie, :tv_show, :anime_series, :cartoon_series]
  """
  @spec all() :: [t()]
  def all, do: @categories

  @doc """
  Returns all movie categories.

  ## Examples

      iex> MediaCategory.movie_categories()
      [:movie, :anime_movie, :cartoon_movie]
  """
  @spec movie_categories() :: [t()]
  def movie_categories, do: [:movie, :anime_movie, :cartoon_movie]

  @doc """
  Returns all TV series categories.

  ## Examples

      iex> MediaCategory.series_categories()
      [:tv_show, :anime_series, :cartoon_series]
  """
  @spec series_categories() :: [t()]
  def series_categories, do: [:tv_show, :anime_series, :cartoon_series]

  @doc """
  Returns all animation categories (both movies and series).

  ## Examples

      iex> MediaCategory.animation_categories()
      [:anime_movie, :cartoon_movie, :anime_series, :cartoon_series]
  """
  @spec animation_categories() :: [t()]
  def animation_categories, do: [:anime_movie, :cartoon_movie, :anime_series, :cartoon_series]

  @doc """
  Returns all anime categories (Japanese animation).

  ## Examples

      iex> MediaCategory.anime_categories()
      [:anime_movie, :anime_series]
  """
  @spec anime_categories() :: [t()]
  def anime_categories, do: [:anime_movie, :anime_series]

  @doc """
  Checks if a category is valid.

  ## Examples

      iex> MediaCategory.valid?(:anime_movie)
      true

      iex> MediaCategory.valid?(:invalid)
      false
  """
  @spec valid?(atom()) :: boolean()
  def valid?(category) when is_atom(category), do: category in @categories
  def valid?(_), do: false

  @doc """
  Checks if the category represents a movie type.

  ## Examples

      iex> MediaCategory.movie?(:anime_movie)
      true

      iex> MediaCategory.movie?(:anime_series)
      false
  """
  @spec movie?(t()) :: boolean()
  def movie?(category), do: category in movie_categories()

  @doc """
  Checks if the category represents a TV series type.

  ## Examples

      iex> MediaCategory.series?(:anime_series)
      true

      iex> MediaCategory.series?(:anime_movie)
      false
  """
  @spec series?(t()) :: boolean()
  def series?(category), do: category in series_categories()

  @doc """
  Checks if the category is animated content.

  ## Examples

      iex> MediaCategory.animated?(:anime_movie)
      true

      iex> MediaCategory.animated?(:movie)
      false
  """
  @spec animated?(t()) :: boolean()
  def animated?(category), do: category in animation_categories()

  @doc """
  Checks if the category is anime (Japanese animation).

  ## Examples

      iex> MediaCategory.anime?(:anime_series)
      true

      iex> MediaCategory.anime?(:cartoon_series)
      false
  """
  @spec anime?(t()) :: boolean()
  def anime?(category), do: category in anime_categories()

  @doc """
  Returns a human-readable label for the category.

  ## Examples

      iex> MediaCategory.label(:anime_movie)
      "Anime Movie"

      iex> MediaCategory.label(:tv_show)
      "TV Show"
  """
  @spec label(t()) :: String.t()
  def label(:movie), do: "Movie"
  def label(:anime_movie), do: "Anime Movie"
  def label(:cartoon_movie), do: "Cartoon Movie"
  def label(:tv_show), do: "TV Show"
  def label(:anime_series), do: "Anime Series"
  def label(:cartoon_series), do: "Cartoon Series"

  @doc """
  Returns a DaisyUI badge color class for the category.

  ## Examples

      iex> MediaCategory.badge_color(:anime_movie)
      "badge-secondary"

      iex> MediaCategory.badge_color(:movie)
      "badge-primary"
  """
  @spec badge_color(t()) :: String.t()
  def badge_color(:movie), do: "badge-primary"
  def badge_color(:anime_movie), do: "badge-secondary"
  def badge_color(:cartoon_movie), do: "badge-accent"
  def badge_color(:tv_show), do: "badge-primary"
  def badge_color(:anime_series), do: "badge-secondary"
  def badge_color(:cartoon_series), do: "badge-accent"

  @doc """
  Returns categories appropriate for a given library type.

  ## Examples

      iex> MediaCategory.for_library_type(:movies)
      [:movie, :anime_movie, :cartoon_movie]

      iex> MediaCategory.for_library_type(:series)
      [:tv_show, :anime_series, :cartoon_series]

      iex> MediaCategory.for_library_type(:mixed)
      [:movie, :anime_movie, :cartoon_movie, :tv_show, :anime_series, :cartoon_series]
  """
  @spec for_library_type(atom()) :: [t()]
  def for_library_type(:movies), do: movie_categories()
  def for_library_type(:series), do: series_categories()
  def for_library_type(:mixed), do: all()
  def for_library_type(_), do: []
end
