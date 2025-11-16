defmodule Mydia.Subtitles.MediaHash do
  @moduledoc """
  Schema for media file hashes used in subtitle matching.

  Stores OpenSubtitles moviehash for video files to enable precise subtitle matching.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  schema "media_hashes" do
    field :media_file_id, :binary_id, primary_key: true
    field :opensubtitles_hash, :string
    field :file_size, :integer
    field :calculated_at, :utc_datetime

    belongs_to :media_file, Mydia.Library.MediaFile,
      foreign_key: :media_file_id,
      define_field: false
  end

  @doc """
  Changeset for creating or updating a media hash.
  """
  def changeset(media_hash, attrs) do
    media_hash
    |> cast(attrs, [:media_file_id, :opensubtitles_hash, :file_size, :calculated_at])
    |> validate_required([:media_file_id, :opensubtitles_hash, :file_size, :calculated_at])
    |> validate_number(:file_size, greater_than: 0)
    |> unique_constraint(:media_file_id, name: :media_hashes_pkey)
    |> foreign_key_constraint(:media_file_id)
  end
end
