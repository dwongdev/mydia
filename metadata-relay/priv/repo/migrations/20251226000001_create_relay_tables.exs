defmodule MetadataRelay.Repo.Migrations.CreateRelayTables do
  use Ecto.Migration

  def change do
    # Relay instances - Mydia servers that register with the relay
    create table(:relay_instances, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :instance_id, :string, null: false
      add :public_key, :binary, null: false
      add :direct_urls, {:array, :string}, default: []
      add :last_seen_at, :utc_datetime
      add :online, :boolean, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:relay_instances, [:instance_id])
    create index(:relay_instances, [:online])

    # Claim codes - temporary codes for device pairing
    create table(:relay_claims, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :code, :string, null: false
      add :instance_id, references(:relay_instances, type: :binary_id, on_delete: :delete_all),
        null: false
      add :user_id, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :consumed_at, :utc_datetime
      add :consumed_by_device_id, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:relay_claims, [:code])
    create index(:relay_claims, [:instance_id])
    create index(:relay_claims, [:expires_at])
  end
end
