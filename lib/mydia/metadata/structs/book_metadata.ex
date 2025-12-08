defmodule Mydia.Metadata.Structs.BookMetadata do
  @moduledoc """
  Represents book metadata from Open Library.
  """

  @enforce_keys [:provider_id, :provider]
  defstruct [
    :provider_id,
    :provider,
    :title,
    :subtitle,
    # List of author names or maps
    :authors,
    :isbn_10,
    :isbn_13,
    :publish_date,
    :publisher,
    :number_of_pages,
    :description,
    :cover_url,
    # Subjects in Open Library
    :genres,
    :series_name,
    :series_position,
    :language,
    # Map of other IDs (Goodreads, LCCCN, etc.)
    :identifiers
  ]

  @type t :: %__MODULE__{
          provider_id: String.t(),
          provider: atom(),
          title: String.t() | nil,
          subtitle: String.t() | nil,
          authors: [String.t()] | nil,
          isbn_10: String.t() | nil,
          isbn_13: String.t() | nil,
          publish_date: Date.t() | String.t() | nil,
          publisher: String.t() | nil,
          number_of_pages: integer() | nil,
          description: String.t() | nil,
          cover_url: String.t() | nil,
          genres: [String.t()] | nil,
          series_name: String.t() | nil,
          series_position: float() | nil,
          language: String.t() | nil,
          identifiers: map() | nil
        }
end
