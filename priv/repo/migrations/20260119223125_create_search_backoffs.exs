defmodule Mydia.Repo.Migrations.CreateSearchBackoffs do
  @moduledoc """
  Creates the search_backoffs table for tracking exponential backoff state
  for searches that fail or have all results filtered out.

  Tracks backoff per resource (movie, tv_show, season, episode) to reduce
  unnecessary API calls when searches consistently fail.
  """
  use Ecto.Migration
  import Mydia.Repo.Migrations.Helpers

  def change do
    create table(:search_backoffs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Polymorphic resource reference
      # resource_type: "movie", "tv_show", "season", "episode"
      # resource_id: media_item_id or episode_id
      add :resource_type, :string, null: false
      add :resource_id, :binary_id, null: false
      # season_number: Only used for season-level backoff
      add :season_number, :integer

      # Backoff state
      add :failure_count, :integer, default: 0, null: false
      add :last_failure_reason, :string
      add :next_eligible_at, :utc_datetime
      add :first_failed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Unique constraint per resource
    # SQLite handles NULL differently in unique indexes, so we use a simple
    # composite index. The COALESCE approach isn't needed since we can use
    # a partial index pattern.
    for_database(
      sqlite: fn ->
        # SQLite: Simple unique index on all three columns
        # NULL values are considered distinct in SQLite unique indexes,
        # which is what we want (allows multiple rows with NULL season_number)
        create unique_index(
                 :search_backoffs,
                 [:resource_type, :resource_id, :season_number],
                 name: :search_backoffs_resource_unique
               )
      end,
      postgres: fn ->
        # PostgreSQL: Use COALESCE to handle NULL season_number
        execute """
        CREATE UNIQUE INDEX search_backoffs_resource_unique
        ON search_backoffs (resource_type, resource_id, COALESCE(season_number, -1))
        """
      end
    )

    # Index for querying eligible resources
    create index(:search_backoffs, [:resource_type, :next_eligible_at])
  end
end
