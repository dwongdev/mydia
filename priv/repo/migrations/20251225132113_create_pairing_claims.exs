defmodule Mydia.Repo.Migrations.CreatePairingClaims do
  use Ecto.Migration

  def change do
    create table(:pairing_claims, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :code, :string, null: false
      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime
      add :device_id, references(:remote_devices, on_delete: :nilify_all, type: :binary_id)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:pairing_claims, [:code])
    create index(:pairing_claims, [:user_id])
    create index(:pairing_claims, [:expires_at])
    create index(:pairing_claims, [:device_id])
  end
end
