defmodule Mydia.Repo.Migrations.RemovePublicPortsFromRemoteAccessConfig do
  use Ecto.Migration

  def change do
    alter table(:remote_access_config) do
      remove :public_port, :integer
      remove :public_https_port, :integer
    end
  end
end
