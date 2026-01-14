defmodule MetadataRelay.Repo.Migrations.AddClaimLock do
  use Ecto.Migration

  def change do
    alter table(:relay_claims) do
      add :locked_at, :utc_datetime
      add :lock_expires_at, :utc_datetime
    end
  end
end
