defmodule MetadataRelay.Relay.PendingRequests do
  @moduledoc """
  Tracks pending relay requests that are awaiting responses from Mydia instances.

  When a client sends a request through the relay to a Mydia instance, we need to
  track it so that:
  1. The response can be routed back to the correct client
  2. If the instance disconnects, pending requests receive a 502 error

  Uses an ETS table with `write_concurrency: true` for optimal concurrent access.

  ## Usage

  Register a pending request when forwarding to an instance:

      PendingRequests.register(instance_id, request_id, self())

  When the response arrives, resolve it:

      PendingRequests.resolve(request_id, response)

  When an instance disconnects, fail all its pending requests:

      PendingRequests.fail_all(instance_id, {:error, :tunnel_disconnected})
  """

  @table :relay_pending_requests
  @default_timeout 30_000

  @doc """
  Creates the ETS table. Must be called before the supervision tree starts.
  """
  def create_table do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
  end

  @doc """
  Registers a pending request.

  ## Parameters

  - `instance_id` - The Mydia instance the request was sent to
  - `request_id` - Unique identifier for this request
  - `from_pid` - The process waiting for the response

  ## Returns

  `:ok`
  """
  @spec register(String.t(), String.t(), pid()) :: :ok
  def register(instance_id, request_id, from_pid) do
    registered_at = System.monotonic_time(:millisecond)
    :ets.insert(@table, {request_id, instance_id, from_pid, registered_at})
    :ok
  end

  @doc """
  Looks up a pending request by request_id.

  ## Parameters

  - `request_id` - The request identifier

  ## Returns

  - `{:ok, instance_id, from_pid}` - Request found
  - `:not_found` - No pending request with this ID
  """
  @spec lookup(String.t()) :: {:ok, String.t(), pid()} | :not_found
  def lookup(request_id) do
    case :ets.lookup(@table, request_id) do
      [{^request_id, instance_id, from_pid, _registered_at}] ->
        {:ok, instance_id, from_pid}

      [] ->
        :not_found
    end
  end

  @doc """
  Resolves a pending request by sending the response to the waiting process
  and removing the request from the table.

  ## Parameters

  - `request_id` - The request identifier
  - `response` - The response to send

  ## Returns

  - `:ok` - Response sent successfully
  - `:not_found` - No pending request with this ID
  """
  @spec resolve(String.t(), any()) :: :ok | :not_found
  def resolve(request_id, response) do
    case lookup(request_id) do
      {:ok, _instance_id, from_pid} ->
        send(from_pid, {:response, request_id, response})
        :ets.delete(@table, request_id)
        :ok

      :not_found ->
        :not_found
    end
  end

  @doc """
  Removes a pending request without sending a response.

  ## Parameters

  - `request_id` - The request identifier

  ## Returns

  `:ok`
  """
  @spec delete(String.t()) :: :ok
  def delete(request_id) do
    :ets.delete(@table, request_id)
    :ok
  end

  @doc """
  Fails all pending requests for an instance, sending error to all waiting processes.

  This should be called when an instance disconnects to prevent clients from
  hanging indefinitely.

  ## Parameters

  - `instance_id` - The instance that disconnected
  - `error` - The error to send (default: `{:error, :tunnel_disconnected}`)

  ## Returns

  The count of failed requests
  """
  @spec fail_all(String.t(), any()) :: non_neg_integer()
  def fail_all(instance_id, error \\ {:error, :tunnel_disconnected}) do
    # Find all pending requests for this instance
    # Match pattern: {request_id, instance_id, from_pid, registered_at}
    match_spec = [
      {
        {:"$1", :"$2", :"$3", :"$4"},
        [{:==, :"$2", instance_id}],
        [{{:"$1", :"$3"}}]
      }
    ]

    requests = :ets.select(@table, match_spec)

    # Send error to each waiting process and delete from table
    Enum.each(requests, fn {request_id, from_pid} ->
      send(from_pid, {:error, request_id, error})
      :ets.delete(@table, request_id)
    end)

    length(requests)
  end

  @doc """
  Awaits a response for a pending request with timeout.

  Registers the request, then blocks until response or timeout.

  ## Parameters

  - `instance_id` - The Mydia instance to send to
  - `request_id` - Unique request identifier
  - `timeout` - Timeout in milliseconds (default: 30_000)

  ## Returns

  - `{:ok, response}` - Response received
  - `{:error, :timeout}` - Timed out waiting for response
  - `{:error, reason}` - Error received (e.g., tunnel disconnected)
  """
  @spec await_response(String.t(), String.t(), non_neg_integer()) ::
          {:ok, any()} | {:error, any()}
  def await_response(instance_id, request_id, timeout \\ @default_timeout) do
    register(instance_id, request_id, self())

    receive do
      {:response, ^request_id, response} ->
        {:ok, response}

      {:error, ^request_id, reason} ->
        {:error, reason}
    after
      timeout ->
        delete(request_id)
        {:error, :timeout}
    end
  end

  @doc """
  Returns the count of pending requests.

  ## Returns

  The total count of pending requests
  """
  @spec count() :: non_neg_integer()
  def count do
    :ets.info(@table, :size)
  end

  @doc """
  Returns the count of pending requests for a specific instance.

  ## Parameters

  - `instance_id` - The instance to count requests for

  ## Returns

  The count of pending requests for this instance
  """
  @spec count_for_instance(String.t()) :: non_neg_integer()
  def count_for_instance(instance_id) do
    match_spec = [
      {
        {:"$1", :"$2", :"$3", :"$4"},
        [{:==, :"$2", instance_id}],
        [true]
      }
    ]

    :ets.select_count(@table, match_spec)
  end

  @doc """
  Lists all pending requests for an instance.

  Useful for debugging and monitoring.

  ## Parameters

  - `instance_id` - The instance to list requests for

  ## Returns

  List of `{request_id, from_pid, registered_at}` tuples
  """
  @spec list_for_instance(String.t()) :: [{String.t(), pid(), integer()}]
  def list_for_instance(instance_id) do
    match_spec = [
      {
        {:"$1", :"$2", :"$3", :"$4"},
        [{:==, :"$2", instance_id}],
        [{{:"$1", :"$3", :"$4"}}]
      }
    ]

    :ets.select(@table, match_spec)
  end
end
