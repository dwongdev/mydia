defmodule Mydia.Repo.Migrations.AddEnvNameToIndexerConfigs do
  use Ecto.Migration

  def change do
    alter table(:indexer_configs) do
      add :env_name, :string
    end
  end
end
