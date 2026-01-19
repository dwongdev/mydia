defmodule MetadataRelay.Relay.ConnectionRegistry do
  @moduledoc """
  ETS-based registry for tracking active relay connections.

  Provides O(1) lookups for connected instances, avoiding database hits on every
  relay operation. Uses `read_concurrency: true` for optimal concurrent read performance.

  ## Usage

  Register a connection when an instance connects:

      ConnectionRegistry.register("instance-123", self(), %{connected_at: DateTime.utc_now()})

  Look up a connection to route messages:

      case ConnectionRegistry.lookup("instance-123") do
        {:ok, pid, metadata} -> send(pid, message)
        :not_found -> {:error, :instance_offline}
      end

  Unregister when the connection closes:

      ConnectionRegistry.unregister("instance-123")
  """

  @table :relay_connections

  @doc """
  Creates the ETS table. Must be called before the supervision tree starts.
  """
  def create_table do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
  end

  @doc """
  Registers an instance connection.

  ## Parameters

  - `instance_id` - The unique instance identifier
  - `pid` - The process handling this connection (usually the socket process)
  - `metadata` - Optional metadata map (e.g., connected_at, public_ip)

  ## Returns

  `:ok`
  """
  @spec register(String.t(), pid(), map()) :: :ok
  def register(instance_id, pid, metadata \\ %{}) do
    :ets.insert(@table, {instance_id, pid, metadata, System.monotonic_time(:millisecond)})
    :ok
  end

  @doc """
  Looks up a registered instance connection.

  ## Parameters

  - `instance_id` - The instance identifier to look up

  ## Returns

  - `{:ok, pid, metadata}` - The connection process and metadata
  - `:not_found` - No active connection for this instance
  """
  @spec lookup(String.t()) :: {:ok, pid(), map()} | :not_found
  def lookup(instance_id) do
    case :ets.lookup(@table, instance_id) do
      [{^instance_id, pid, metadata, _registered_at}] ->
        {:ok, pid, metadata}

      [] ->
        :not_found
    end
  end

  @doc """
  Checks if an instance is currently connected.

  ## Parameters

  - `instance_id` - The instance identifier to check

  ## Returns

  `true` if connected, `false` otherwise
  """
  @spec online?(String.t()) :: boolean()
  def online?(instance_id) do
    case lookup(instance_id) do
      {:ok, _pid, _metadata} -> true
      :not_found -> false
    end
  end

  @doc """
  Unregisters an instance connection.

  ## Parameters

  - `instance_id` - The instance identifier to unregister

  ## Returns

  `:ok`
  """
  @spec unregister(String.t()) :: :ok
  def unregister(instance_id) do
    :ets.delete(@table, instance_id)
    :ok
  end

  @doc """
  Lists all currently connected instances.

  ## Returns

  A list of tuples: `[{instance_id, pid, metadata, registered_at}]`
  """
  @spec list_online() :: [{String.t(), pid(), map(), integer()}]
  def list_online do
    :ets.tab2list(@table)
  end

  @doc """
  Returns the count of currently connected instances.

  ## Returns

  The number of active connections
  """
  @spec count() :: non_neg_integer()
  def count do
    :ets.info(@table, :size)
  end

  @doc """
  Gets the process ID for an instance if connected.

  ## Parameters

  - `instance_id` - The instance identifier

  ## Returns

  - `{:ok, pid}` - The connection process
  - `:not_found` - No active connection
  """
  @spec get_pid(String.t()) :: {:ok, pid()} | :not_found
  def get_pid(instance_id) do
    case lookup(instance_id) do
      {:ok, pid, _metadata} -> {:ok, pid}
      :not_found -> :not_found
    end
  end
end
