defmodule Mydia.RemoteAccess.RequestExecutor do
  @moduledoc """
  Executes remote access requests with independent timeouts.

  Uses Task.Supervisor to spawn each request in its own task, preventing slow
  requests from blocking others. Provides clean timeout handling with Task.yield/shutdown.

  ## Usage

  Execute a request with default 30-second timeout:

      RequestExecutor.execute(fn -> do_work() end)

  Execute with custom timeout:

      RequestExecutor.execute(fn -> do_work() end, timeout: 60_000)

  Execute async (fire and forget):

      RequestExecutor.async(fn -> do_work() end)

  ## Error Handling

  - Returns `{:ok, result}` on success
  - Returns `{:error, :timeout}` if request times out
  - Returns `{:error, {:exception, exception}}` if request raises
  """

  require Logger

  @default_timeout 30_000
  @supervisor Mydia.RequestTaskSupervisor

  @doc """
  Executes a function in a supervised task with timeout.

  The function runs in a separate process so it doesn't block the caller.
  If the function takes longer than the timeout, the task is shut down cleanly.

  ## Options

  - `:timeout` - Timeout in milliseconds (default: 30_000)
  - `:on_timeout` - Callback function called on timeout (default: none)

  ## Returns

  - `{:ok, result}` - Function completed successfully
  - `{:error, :timeout}` - Function timed out
  - `{:error, {:exception, exception}}` - Function raised an exception
  """
  @spec execute(fun(), keyword()) :: {:ok, any()} | {:error, any()}
  def execute(fun, opts \\ []) when is_function(fun, 0) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    on_timeout = Keyword.get(opts, :on_timeout)

    task = Task.Supervisor.async_nolink(@supervisor, fun)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} ->
        {:ok, result}

      {:exit, reason} ->
        Logger.warning("Request task exited: #{inspect(reason)}")
        {:error, {:exception, reason}}

      nil ->
        Logger.debug("Request task timed out after #{timeout}ms")

        if on_timeout do
          on_timeout.()
        end

        {:error, :timeout}
    end
  end

  @doc """
  Executes a function in a supervised task without waiting for the result.

  Useful for fire-and-forget operations where you don't need the result.
  The task runs independently and any errors are logged but not returned.

  ## Returns

  `{:ok, Task.t()}` - The task struct for monitoring if needed
  """
  @spec async(fun()) :: {:ok, Task.t()}
  def async(fun) when is_function(fun, 0) do
    task = Task.Supervisor.async_nolink(@supervisor, fun)
    {:ok, task}
  end

  @doc """
  Executes multiple functions concurrently and waits for all results.

  Each function runs in its own supervised task with the specified timeout.
  Returns results in the same order as the input functions.

  ## Options

  - `:timeout` - Timeout for each individual task (default: 30_000)
  - `:ordered` - Whether to return results in order (default: true)

  ## Returns

  List of results where each element is either:
  - `{:ok, result}` - Function completed successfully
  - `{:error, :timeout}` - Function timed out
  - `{:error, {:exception, reason}}` - Function raised an exception
  """
  @spec execute_all([fun()], keyword()) :: [{:ok, any()} | {:error, any()}]
  def execute_all(funs, opts \\ []) when is_list(funs) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    # Start all tasks
    tasks =
      Enum.map(funs, fn fun ->
        Task.Supervisor.async_nolink(@supervisor, fun)
      end)

    # Wait for all with timeout
    Enum.map(tasks, fn task ->
      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, result} ->
          {:ok, result}

        {:exit, reason} ->
          {:error, {:exception, reason}}

        nil ->
          {:error, :timeout}
      end
    end)
  end

  @doc """
  Returns the current supervisor for this module.

  Useful for diagnostics and testing.
  """
  @spec supervisor() :: atom()
  def supervisor, do: @supervisor

  @doc """
  Returns the default timeout in milliseconds.
  """
  @spec default_timeout() :: non_neg_integer()
  def default_timeout, do: @default_timeout
end
