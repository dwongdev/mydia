defmodule Mydia.Repo.Migrations.AddApiKeyFields do
  use Ecto.Migration

  def change do
    alter table(:api_keys) do
      add :key_prefix, :string
      add :permissions, :text
      add :revoked_at, :utc_datetime
    end

    create index(:api_keys, [:key_prefix])
  end
end
