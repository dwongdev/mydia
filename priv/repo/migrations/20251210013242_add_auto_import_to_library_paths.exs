defmodule Mydia.Repo.Migrations.AddAutoImportToLibraryPaths do
  use Ecto.Migration

  def change do
    alter table(:library_paths) do
      add :auto_import, :boolean, default: false
    end
  end
end
