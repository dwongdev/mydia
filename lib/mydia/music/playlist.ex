defmodule Mydia.Music.Playlist do
  @moduledoc """
  Schema for music playlists.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "playlists" do
    field :name, :string
    field :description, :string
    field :cover_url, :string
    field :public, :boolean, default: false
    field :track_count, :integer, default: 0
    field :total_duration, :integer, default: 0

    belongs_to :user, Mydia.Accounts.User
    has_many :playlist_tracks, Mydia.Music.PlaylistTrack

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a playlist.
  """
  def changeset(playlist, attrs) do
    playlist
    |> cast(attrs, [:name, :description, :cover_url, :public])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 200)
    |> validate_length(:description, max: 1000)
  end

  @doc """
  Changeset for updating playlist stats (track count and total duration).
  These are managed programmatically and not through user input.
  """
  def stats_changeset(playlist, attrs) do
    playlist
    |> cast(attrs, [:track_count, :total_duration])
  end
end
