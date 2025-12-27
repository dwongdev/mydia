defmodule Mydia.Streaming.HlsSessionReadyTest do
  @moduledoc """
  Tests for HLS session ready state functionality.

  These tests verify the await_ready/notify_ready mechanism that allows
  the controller to wait for FFmpeg to produce the first playlist.
  """

  use ExUnit.Case, async: true

  defmodule MockSession do
    @moduledoc """
    A minimal GenServer that mimics HlsSession's ready state behavior
    for testing purposes (without needing actual FFmpeg/media files).
    """
    use GenServer

    defstruct ready: false, ready_waiters: []

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts)
    end

    def await_ready(pid, timeout \\ 30_000) do
      GenServer.call(pid, :await_ready, timeout)
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
    end

    def notify_ready(pid) do
      GenServer.cast(pid, :notify_ready)
    end

    @impl true
    def init(_opts) do
      {:ok, %__MODULE__{}}
    end

    @impl true
    def handle_call(:await_ready, _from, %{ready: true} = state) do
      {:reply, :ok, state}
    end

    def handle_call(:await_ready, from, state) do
      {:noreply, %{state | ready_waiters: [from | state.ready_waiters]}}
    end

    @impl true
    def handle_cast(:notify_ready, %{ready: true} = state) do
      {:noreply, state}
    end

    def handle_cast(:notify_ready, state) do
      Enum.each(state.ready_waiters, fn from ->
        GenServer.reply(from, :ok)
      end)

      {:noreply, %{state | ready: true, ready_waiters: []}}
    end
  end

  describe "await_ready/2" do
    test "returns immediately when already ready" do
      {:ok, pid} = MockSession.start_link()

      # Notify ready first
      MockSession.notify_ready(pid)
      # Small delay to ensure cast is processed
      Process.sleep(10)

      # Should return immediately
      assert MockSession.await_ready(pid) == :ok
    end

    test "blocks until notify_ready is called" do
      {:ok, pid} = MockSession.start_link()

      # Start a task that will wait for ready
      task =
        Task.async(fn ->
          MockSession.await_ready(pid)
        end)

      # Give the task time to start waiting
      Process.sleep(50)

      # Notify ready
      MockSession.notify_ready(pid)

      # Task should complete with :ok
      assert Task.await(task) == :ok
    end

    test "multiple waiters all get notified" do
      {:ok, pid} = MockSession.start_link()

      # Start multiple tasks waiting
      tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            MockSession.await_ready(pid)
          end)
        end

      # Give tasks time to start waiting
      Process.sleep(50)

      # Notify ready once
      MockSession.notify_ready(pid)

      # All tasks should complete with :ok
      results = Enum.map(tasks, &Task.await/1)
      assert Enum.all?(results, &(&1 == :ok))
    end

    test "returns {:error, :timeout} when timeout expires" do
      {:ok, pid} = MockSession.start_link()

      # Wait with a very short timeout
      result = MockSession.await_ready(pid, 50)

      assert result == {:error, :timeout}
    end

    test "duplicate notify_ready calls are ignored" do
      {:ok, pid} = MockSession.start_link()

      # Notify ready multiple times
      MockSession.notify_ready(pid)
      Process.sleep(10)
      MockSession.notify_ready(pid)
      MockSession.notify_ready(pid)

      # Should still return :ok
      assert MockSession.await_ready(pid) == :ok
    end
  end

  describe "notify_ready/1" do
    test "sets ready state to true" do
      {:ok, pid} = MockSession.start_link()

      # Initially not ready, so this would block
      # Let's verify by calling await_ready after notify

      MockSession.notify_ready(pid)
      Process.sleep(10)

      # Now should return immediately
      assert MockSession.await_ready(pid, 100) == :ok
    end
  end
end
