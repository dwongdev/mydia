defmodule Mydia.Repo.Migrations.CreateMediaServerConfigs do
  use Ecto.Migration

  def change do
    create table(:media_server_configs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :type, :string, null: false
      add :enabled, :boolean, default: true
      add :url, :string, null: false
      add :token, :string
      add :connection_settings, :text
      add :updated_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:media_server_configs, [:name])
    create index(:media_server_configs, [:enabled])
    create index(:media_server_configs, [:type])
  end
end
