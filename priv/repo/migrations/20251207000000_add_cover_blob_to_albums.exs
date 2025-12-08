defmodule Mydia.Repo.Migrations.AddCoverBlobToAlbums do
  use Ecto.Migration

  def change do
    alter table(:albums) do
      add :cover_blob, :string
      add :cover_source, :string
    end
  end
end
