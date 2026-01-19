defmodule Mydia.Repo.Migrations.AddCertFingerprintToRemoteAccessConfig do
  use Ecto.Migration

  def change do
    alter table(:remote_access_config) do
      add :cert_fingerprint, :string
    end
  end
end
