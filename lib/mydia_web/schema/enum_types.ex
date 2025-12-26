defmodule MydiaWeb.Schema.EnumTypes do
  @moduledoc """
  GraphQL enum type definitions.
  """

  use Absinthe.Schema.Notation

  @desc "Media content types"
  enum :media_type do
    value(:movie, description: "A movie")
    value(:tv_show, description: "A TV show")
  end

  @desc "Library path type"
  enum :library_type do
    value(:movies, description: "Movie library")
    value(:series, description: "TV series library")
    value(:mixed, description: "Mixed content library")
    value(:music, description: "Music library")
    value(:books, description: "Book library")
    value(:adult, description: "Adult content library")
  end

  @desc "Sort field for media lists"
  enum :sort_field do
    value(:title, description: "Sort by title")
    value(:added_at, description: "Sort by date added")
    value(:year, description: "Sort by year")
    value(:rating, description: "Sort by rating")
  end

  @desc "Sort direction"
  enum :sort_direction do
    value(:asc, description: "Ascending order")
    value(:desc, description: "Descending order")
  end

  @desc "Media category (auto-classified or user-override)"
  enum :media_category do
    value(:movie, description: "Standard movie")
    value(:anime_movie, description: "Anime movie")
    value(:cartoon_movie, description: "Animated/cartoon movie")
    value(:tv_show, description: "Standard TV show")
    value(:anime_series, description: "Anime series")
    value(:cartoon_series, description: "Animated/cartoon series")
  end
end
