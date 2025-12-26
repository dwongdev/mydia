defmodule Mydia.Repo.Migrations.CreateRemoteAccessTables do
  use Ecto.Migration

  def change do
    # Instance identity and relay configuration
    create table(:remote_access_config, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :instance_id, :string, null: false
      add :static_public_key, :binary, null: false
      add :static_private_key_encrypted, :binary, null: false
      add :relay_url, :string, null: false
      add :enabled, :boolean, default: false, null: false
      add :direct_urls, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:remote_access_config, [:instance_id])

    # Paired client devices
    create table(:remote_devices, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :device_name, :string, null: false
      add :platform, :string, null: false
      add :device_static_public_key, :binary, null: false
      add :token_hash, :string, null: false
      add :last_seen_at, :utc_datetime
      add :revoked_at, :utc_datetime
      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:remote_devices, [:token_hash])
    create index(:remote_devices, [:user_id])
    create index(:remote_devices, [:device_static_public_key])
  end
end
