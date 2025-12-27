defmodule MetadataRelay.RateLimiter do
  @moduledoc """
  Simple in-memory rate limiter using ETS.

  Limits requests per IP address over a time window.
  """

  use GenServer

  @table_name :rate_limiter
  # 10 requests per minute per IP
  @max_requests 10
  @window_ms 60_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Check if a request from the given identifier should be allowed.

  Returns `{:ok, remaining}` if allowed, `{:error, :rate_limited}` if blocked.

  ## Options

  - `:limit` - Maximum number of requests allowed (default: #{@max_requests})
  - `:window_ms` - Time window in milliseconds (default: #{@window_ms})
  """
  def check_rate_limit(identifier, opts \\ []) do
    max_requests = Keyword.get(opts, :limit, @max_requests)
    window_ms = Keyword.get(opts, :window_ms, @window_ms)

    now = System.monotonic_time(:millisecond)
    window_start = now - window_ms

    # Clean up old entries for all identifiers
    :ets.select_delete(@table_name, [
      {{:"$1", :"$2", :"$3"}, [{:<, :"$3", window_start}], [true]}
    ])

    # Count requests in current window for this identifier
    count =
      :ets.select_count(@table_name, [
        {{identifier, :"$1", :"$2"}, [{:>=, :"$2", window_start}], [true]}
      ])

    if count < max_requests do
      # Insert with unique key: {identifier, request_id, timestamp}
      request_id = :erlang.unique_integer([:monotonic])
      :ets.insert(@table_name, {identifier, request_id, now})
      {:ok, max_requests - count - 1}
    else
      {:error, :rate_limited}
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [:bag, :public, :named_table])
    {:ok, %{}}
  end
end
