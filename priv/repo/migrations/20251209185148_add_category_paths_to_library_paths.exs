defmodule Mydia.Repo.Migrations.AddCategoryPathsToLibraryPaths do
  use Ecto.Migration

  def change do
    alter table(:library_paths) do
      # Map of category -> relative path (e.g., %{"anime_movie" => "Anime Movies"})
      add :category_paths, :map, default: %{}
      # Enable/disable auto-organization for this library
      add :auto_organize, :boolean, default: false
    end
  end
end
