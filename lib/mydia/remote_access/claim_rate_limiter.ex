defmodule Mydia.RemoteAccess.ClaimRateLimiter do
  @moduledoc """
  Rate limiter for claim code validation attempts.
  Limits failed validation attempts per IP address to prevent brute force attacks.
  """
  use GenServer

  @table_name :claim_rate_limiter
  @max_attempts 5
  @window_seconds 3600

  # 1 hour

  # Client API

  @doc """
  Starts the rate limiter GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks if an IP address is allowed to attempt validation.
  Returns :ok if allowed, {:error, :rate_limited} if not.
  """
  def check_rate_limit(ip_address) when is_binary(ip_address) do
    key = rate_limit_key(ip_address)
    now = System.system_time(:second)

    case :ets.lookup(@table_name, key) do
      [] ->
        :ok

      [{^key, attempts, first_attempt_at}] ->
        if now - first_attempt_at > @window_seconds do
          # Window has expired, reset
          :ets.delete(@table_name, key)
          :ok
        else
          if attempts >= @max_attempts do
            {:error, :rate_limited}
          else
            :ok
          end
        end
    end
  end

  @doc """
  Records a failed validation attempt for an IP address.
  """
  def record_failed_attempt(ip_address) when is_binary(ip_address) do
    key = rate_limit_key(ip_address)
    now = System.system_time(:second)

    case :ets.lookup(@table_name, key) do
      [] ->
        :ets.insert(@table_name, {key, 1, now})

      [{^key, attempts, first_attempt_at}] ->
        if now - first_attempt_at > @window_seconds do
          # Window has expired, reset counter
          :ets.insert(@table_name, {key, 1, now})
        else
          :ets.insert(@table_name, {key, attempts + 1, first_attempt_at})
        end
    end

    :ok
  end

  @doc """
  Resets the rate limit for an IP address (e.g., after successful validation).
  """
  def reset_rate_limit(ip_address) when is_binary(ip_address) do
    key = rate_limit_key(ip_address)
    :ets.delete(@table_name, key)
    :ok
  end

  @doc """
  Cleans up expired entries from the rate limiter table.
  """
  def cleanup_expired do
    now = System.system_time(:second)

    :ets.foldl(
      fn {key, _attempts, first_attempt_at}, acc ->
        if now - first_attempt_at > @window_seconds do
          :ets.delete(@table_name, key)
        end

        acc
      end,
      nil,
      @table_name
    )

    :ok
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for storing rate limit data
    :ets.new(@table_name, [:named_table, :public, :set])

    # Schedule periodic cleanup every 10 minutes
    schedule_cleanup()

    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  # Private functions

  defp rate_limit_key(ip_address) do
    "claim_validation:#{ip_address}"
  end

  defp schedule_cleanup do
    # Schedule cleanup every 10 minutes
    Process.send_after(self(), :cleanup, :timer.minutes(10))
  end
end
