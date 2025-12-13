defmodule Mydia.Repo.Migrations.AddSeasonsRefreshedAtToMediaItems do
  use Ecto.Migration

  def change do
    alter table(:media_items) do
      add :seasons_refreshed_at, :utc_datetime
    end
  end
end
