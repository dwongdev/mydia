defmodule Mydia.Repo.Migrations.AddCategoryToMediaItems do
  use Ecto.Migration

  def change do
    alter table(:media_items) do
      add :category, :string
      add :category_override, :boolean, default: false, null: false
    end

    create index(:media_items, [:category])
  end
end
