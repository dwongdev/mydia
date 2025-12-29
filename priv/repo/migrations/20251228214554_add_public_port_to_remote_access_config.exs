defmodule Mydia.Repo.Migrations.AddPublicPortToRemoteAccessConfig do
  use Ecto.Migration

  def change do
    alter table(:remote_access_config) do
      add :public_port, :integer
    end
  end
end
