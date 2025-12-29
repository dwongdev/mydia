defmodule Mydia.Repo.Migrations.AddTargetCollectionToImportLists do
  use Ecto.Migration

  def change do
    alter table(:import_lists) do
      add :target_collection_id, references(:collections, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:import_lists, [:target_collection_id])
  end
end
