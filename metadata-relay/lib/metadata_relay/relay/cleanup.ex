defmodule MetadataRelay.Relay.Cleanup do
  @moduledoc """
  Periodic cleanup process for expired relay claims and stale instances.

  Runs at regular intervals to:
  - Delete expired and consumed claim codes
  - Mark instances as offline if they haven't sent heartbeats
  """

  use GenServer
  require Logger

  alias MetadataRelay.Relay

  # Run cleanup every 5 minutes
  @cleanup_interval 300_000

  # Instance is considered stale after 2 minutes without heartbeat
  @instance_stale_seconds 120

  # Clean up claims older than 24 hours
  @claim_max_age_seconds 86400

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Schedule first cleanup
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    perform_cleanup()
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp perform_cleanup do
    cleanup_claims()
    cleanup_stale_instances()
  end

  defp cleanup_claims do
    count = Relay.cleanup_claims(@claim_max_age_seconds)

    if count > 0 do
      Logger.info("Cleaned up #{count} expired relay claims")
    end
  end

  defp cleanup_stale_instances do
    import Ecto.Query
    alias MetadataRelay.Repo
    alias MetadataRelay.Relay.Instance

    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@instance_stale_seconds, :second)

    # Find online instances that haven't sent a heartbeat recently
    query =
      from(i in Instance,
        where: i.online == true and i.last_seen_at < ^cutoff
      )

    stale_instances = Repo.all(query)

    for instance <- stale_instances do
      Logger.info("Marking instance #{instance.instance_id} as offline (stale)")
      Relay.set_offline(instance)
    end

    if length(stale_instances) > 0 do
      Logger.info("Marked #{length(stale_instances)} stale instances as offline")
    end
  end
end
