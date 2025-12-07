defmodule Mydia.Repo.Migrations.CreateImportListsTables do
  use Ecto.Migration

  def change do
    # Import lists table - stores import list configurations
    create table(:import_lists, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :type, :string, null: false
      add :media_type, :string, null: false
      add :enabled, :boolean, default: true, null: false
      add :sync_interval, :integer, default: 360, null: false
      add :auto_add, :boolean, default: false, null: false
      add :monitored, :boolean, default: true, null: false
      add :config, :map, default: %{}
      add :last_synced_at, :utc_datetime
      add :sync_error, :string

      add :quality_profile_id,
          references(:quality_profiles, type: :binary_id, on_delete: :nilify_all)

      add :library_path_id,
          references(:library_paths, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:import_lists, [:type])
    create index(:import_lists, [:media_type])
    create index(:import_lists, [:enabled])

    create unique_index(:import_lists, [:type, :media_type],
             name: :import_lists_type_media_type_unique
           )

    # Import list items table - stores individual items from synced lists
    create table(:import_list_items, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :import_list_id, references(:import_lists, type: :binary_id, on_delete: :delete_all),
        null: false

      add :tmdb_id, :integer, null: false
      add :title, :string, null: false
      add :year, :integer
      add :poster_path, :string
      add :status, :string, default: "pending", null: false
      add :skip_reason, :string
      add :discovered_at, :utc_datetime, null: false

      add :media_item_id,
          references(:media_items, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:import_list_items, [:import_list_id])
    create index(:import_list_items, [:tmdb_id])
    create index(:import_list_items, [:status])
    create index(:import_list_items, [:media_item_id])

    create unique_index(:import_list_items, [:import_list_id, :tmdb_id],
             name: :import_list_items_list_tmdb_unique
           )
  end
end
