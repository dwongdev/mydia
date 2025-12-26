defmodule Mydia.Repo.Migrations.RemoveRelayUrlFromRemoteAccessConfig do
  use Ecto.Migration

  def change do
    alter table(:remote_access_config) do
      remove :relay_url, :string
    end
  end
end
