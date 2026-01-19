defmodule Mydia.Repo.Migrations.CreateUserFavorites do
  use Ecto.Migration

  def change do
    create table(:user_favorites, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false

      add :media_item_id, references(:media_items, on_delete: :delete_all, type: :binary_id),
        null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_favorites, [:user_id, :media_item_id])
    create index(:user_favorites, [:user_id])
    create index(:user_favorites, [:media_item_id])
  end
end
