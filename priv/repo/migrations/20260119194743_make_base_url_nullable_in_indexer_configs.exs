defmodule Mydia.Repo.Migrations.MakeBaseUrlNullableInIndexerConfigs do
  @moduledoc """
  Make base_url nullable for indexer configs.

  When env_name is set, the base_url can be loaded from environment variables
  at runtime, so it doesn't need to be stored in the database.

  SQLite: Recreates the table (doesn't support ALTER COLUMN).
  PostgreSQL: Uses ALTER COLUMN DROP NOT NULL.
  """
  use Ecto.Migration
  import Mydia.Repo.Migrations.Helpers

  def up do
    for_database(
      sqlite: fn -> sqlite_recreate_table_nullable() end,
      postgres: fn ->
        execute "ALTER TABLE indexer_configs ALTER COLUMN base_url DROP NOT NULL"
      end
    )
  end

  def down do
    for_database(
      sqlite: fn -> sqlite_recreate_table_not_null() end,
      postgres: fn ->
        # May fail if null values exist
        execute "ALTER TABLE indexer_configs ALTER COLUMN base_url SET NOT NULL"
      end
    )
  end

  # SQLite: Recreate table with nullable base_url
  defp sqlite_recreate_table_nullable do
    execute """
    CREATE TABLE indexer_configs_new (
      id BLOB PRIMARY KEY,
      name TEXT NOT NULL,
      type TEXT NOT NULL,
      enabled INTEGER DEFAULT 1,
      priority INTEGER DEFAULT 1,
      base_url TEXT,
      api_key TEXT,
      indexer_ids TEXT,
      categories TEXT,
      rate_limit INTEGER,
      connection_settings TEXT,
      env_name TEXT,
      updated_by_id BLOB REFERENCES users(id) ON DELETE SET NULL,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """

    execute "INSERT INTO indexer_configs_new SELECT * FROM indexer_configs"
    execute "DROP TABLE indexer_configs"
    execute "ALTER TABLE indexer_configs_new RENAME TO indexer_configs"

    create unique_index(:indexer_configs, [:name])
    create index(:indexer_configs, [:enabled])
    create index(:indexer_configs, [:priority])
    create index(:indexer_configs, [:type])
  end

  # SQLite: Recreate table with NOT NULL base_url
  defp sqlite_recreate_table_not_null do
    execute """
    CREATE TABLE indexer_configs_new (
      id BLOB PRIMARY KEY,
      name TEXT NOT NULL,
      type TEXT NOT NULL,
      enabled INTEGER DEFAULT 1,
      priority INTEGER DEFAULT 1,
      base_url TEXT NOT NULL,
      api_key TEXT,
      indexer_ids TEXT,
      categories TEXT,
      rate_limit INTEGER,
      connection_settings TEXT,
      env_name TEXT,
      updated_by_id BLOB REFERENCES users(id) ON DELETE SET NULL,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """

    execute "INSERT INTO indexer_configs_new SELECT * FROM indexer_configs"
    execute "DROP TABLE indexer_configs"
    execute "ALTER TABLE indexer_configs_new RENAME TO indexer_configs"

    create unique_index(:indexer_configs, [:name])
    create index(:indexer_configs, [:enabled])
    create index(:indexer_configs, [:priority])
    create index(:indexer_configs, [:type])
  end
end
