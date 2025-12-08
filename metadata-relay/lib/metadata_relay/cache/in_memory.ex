defmodule MetadataRelay.Cache.InMemory do
  @moduledoc """
  In-memory cache adapter using ETS.

  Provides fast, local caching with TTL and size limits.
  Cache contents are lost on service restart.
  """

  use GenServer
  require Logger

  @behaviour MetadataRelay.Cache.Adapter

  @table_name :metadata_relay_cache
  @stats_table :metadata_relay_cache_stats
  @cleanup_interval :timer.minutes(15)
  @max_entries 20_000

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl MetadataRelay.Cache.Adapter
  def get(key) do
    case :ets.lookup(@table_name, key) do
      [{^key, value, expires_at}] ->
        if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
          Logger.debug("Cache hit: #{key}")
          increment_hits()
          {:ok, value}
        else
          # Expired entry
          :ets.delete(@table_name, key)
          increment_misses()
          {:error, :not_found}
        end

      [] ->
        increment_misses()
        {:error, :not_found}
    end
  end

  @impl MetadataRelay.Cache.Adapter
  def put(key, value, ttl) do
    expires_at = DateTime.add(DateTime.utc_now(), ttl, :millisecond)

    # Check size limit and evict if necessary
    if :ets.info(@table_name, :size) >= @max_entries do
      evict_oldest()
    end

    :ets.insert(@table_name, {key, value, expires_at})
    Logger.debug("Cache put: #{key} (TTL: #{ttl}ms)")
    :ok
  end

  @impl MetadataRelay.Cache.Adapter
  def clear do
    :ets.delete_all_objects(@table_name)
    # Also reset stats counters
    :ets.insert(@stats_table, {:hits, 0})
    :ets.insert(@stats_table, {:misses, 0})
    :ok
  end

  @impl MetadataRelay.Cache.Adapter
  def stats do
    size = :ets.info(@table_name, :size)
    memory_words = :ets.info(@table_name, :memory)
    memory_bytes = memory_words * :erlang.system_info(:wordsize)
    memory_mb = Float.round(memory_bytes / 1_024_000, 2)

    hits = get_counter(:hits)
    misses = get_counter(:misses)
    total = hits + misses
    hit_rate = if total > 0, do: Float.round(hits / total * 100, 1), else: 0.0

    %{
      adapter: "in_memory",
      size: size,
      max_entries: @max_entries,
      memory_mb: memory_mb,
      memory_bytes: memory_bytes,
      utilization_pct: Float.round(size / @max_entries * 100, 1),
      hits: hits,
      misses: misses,
      total_requests: total,
      hit_rate_pct: hit_rate
    }
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@stats_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.insert(@stats_table, {:hits, 0})
    :ets.insert(@stats_table, {:misses, 0})
    schedule_cleanup()
    Logger.info("In-memory cache adapter started")
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  ## Private Functions

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp cleanup_expired do
    now = DateTime.utc_now()

    expired_count =
      :ets.select_delete(@table_name, [
        {{:"$1", :"$2", :"$3"}, [{:<, :"$3", {:const, now}}], [true]}
      ])

    if expired_count > 0 do
      Logger.debug("Cleaned up #{expired_count} expired cache entries")
    end
  end

  defp evict_oldest do
    # Simple LRU: delete first entry (oldest based on insertion order)
    case :ets.first(@table_name) do
      :"$end_of_table" -> :ok
      key -> :ets.delete(@table_name, key)
    end
  end

  defp increment_hits do
    :ets.update_counter(@stats_table, :hits, 1, {:hits, 0})
  end

  defp increment_misses do
    :ets.update_counter(@stats_table, :misses, 1, {:misses, 0})
  end

  defp get_counter(key) do
    case :ets.lookup(@stats_table, key) do
      [{^key, count}] -> count
      [] -> 0
    end
  end
end
