defmodule Mydia.Repo.Migrations.CreateCollections do
  use Ecto.Migration

  def change do
    create table(:collections, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :type, :string, null: false, default: "manual"
      add :poster_path, :string
      add :sort_order, :string, null: false, default: "position"
      add :smart_rules, :text
      add :visibility, :string, null: false, default: "private"
      add :is_system, :boolean, null: false, default: false
      add :position, :integer, null: false, default: 0
      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:collections, [:user_id])
    create index(:collections, [:visibility])
    create index(:collections, [:type])
    create index(:collections, [:is_system])

    create table(:collection_items, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :collection_id, references(:collections, on_delete: :delete_all, type: :binary_id),
        null: false

      add :media_item_id, references(:media_items, on_delete: :delete_all, type: :binary_id),
        null: false

      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:collection_items, [:collection_id, :media_item_id])
    create index(:collection_items, [:collection_id])
    create index(:collection_items, [:media_item_id])
  end
end
