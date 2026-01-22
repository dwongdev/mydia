defmodule MetadataRelay.Repo.Migrations.DropRelayTables do
  use Ecto.Migration

  def up do
    # Drop relay tables (claims first due to foreign key)
    drop_if_exists table(:relay_claims)
    drop_if_exists table(:relay_instances)

    # Drop pairing_claims - now using Redis instead
    drop_if_exists table(:pairing_claims)
  end

  def down do
    # Recreate relay_instances table
    create table(:relay_instances, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :instance_id, :string, null: false
      add :public_key, :binary, null: false
      add :direct_urls, {:array, :string}, default: []
      add :last_seen_at, :utc_datetime
      add :online, :boolean, default: false
      add :public_ip, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:relay_instances, [:instance_id])
    create index(:relay_instances, [:online])

    # Recreate relay_claims table
    create table(:relay_claims, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :code, :string, null: false

      add :instance_id, references(:relay_instances, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :consumed_at, :utc_datetime
      add :consumed_by_device_id, :string
      add :locked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:relay_claims, [:code])
    create index(:relay_claims, [:instance_id])
    create index(:relay_claims, [:expires_at])

    # Recreate pairing_claims table
    create table(:pairing_claims, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :code, :string, null: false
      add :node_addr, :text, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:pairing_claims, [:code])
    create index(:pairing_claims, [:expires_at])
  end
end
