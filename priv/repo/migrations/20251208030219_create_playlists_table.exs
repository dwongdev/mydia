defmodule Mydia.Repo.Migrations.CreatePlaylistsTable do
  use Ecto.Migration

  def change do
    create table(:playlists, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :string
      add :cover_url, :string
      add :public, :boolean, default: false, null: false
      add :track_count, :integer, default: 0
      add :total_duration, :integer, default: 0
      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:playlists, [:user_id])

    create table(:playlist_tracks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :position, :integer, null: false
      add :added_at, :utc_datetime, null: false

      add :playlist_id, references(:playlists, on_delete: :delete_all, type: :binary_id),
        null: false

      add :track_id, references(:tracks, on_delete: :delete_all, type: :binary_id), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:playlist_tracks, [:playlist_id])
    create index(:playlist_tracks, [:track_id])
  end
end
