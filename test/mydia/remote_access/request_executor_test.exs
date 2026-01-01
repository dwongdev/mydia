defmodule Mydia.RemoteAccess.RequestExecutorTest do
  use ExUnit.Case, async: true

  alias Mydia.RemoteAccess.RequestExecutor

  describe "execute/2" do
    test "returns {:ok, result} for successful execution" do
      result = RequestExecutor.execute(fn -> 1 + 1 end)
      assert {:ok, 2} = result
    end

    test "returns {:ok, result} for complex return values" do
      result = RequestExecutor.execute(fn -> %{status: :ok, data: [1, 2, 3]} end)
      assert {:ok, %{status: :ok, data: [1, 2, 3]}} = result
    end

    test "returns {:error, :timeout} when function takes too long" do
      result = RequestExecutor.execute(fn -> Process.sleep(200) end, timeout: 50)
      assert {:error, :timeout} = result
    end

    test "does not block caller while executing" do
      # Start a slow task
      parent = self()

      spawn(fn ->
        send(parent, :started)
        RequestExecutor.execute(fn -> Process.sleep(100) end)
        send(parent, :finished)
      end)

      # Should receive :started quickly
      assert_receive :started, 50
      # And :finished after the sleep
      assert_receive :finished, 200
    end

    test "calls on_timeout callback when function times out" do
      parent = self()

      on_timeout = fn ->
        send(parent, :timed_out)
      end

      RequestExecutor.execute(fn -> Process.sleep(200) end,
        timeout: 50,
        on_timeout: on_timeout
      )

      assert_receive :timed_out, 100
    end

    test "handles exceptions gracefully" do
      result = RequestExecutor.execute(fn -> raise "test error" end)
      assert {:error, {:exception, _}} = result
    end

    test "uses default timeout when not specified" do
      assert RequestExecutor.default_timeout() == 30_000
    end
  end

  describe "async/1" do
    test "returns {:ok, task} for async execution" do
      {:ok, task} = RequestExecutor.async(fn -> :done end)
      assert %Task{} = task
    end

    test "task executes independently" do
      parent = self()

      {:ok, _task} =
        RequestExecutor.async(fn ->
          Process.sleep(10)
          send(parent, :done)
        end)

      assert_receive :done, 100
    end

    test "errors in async tasks don't crash caller" do
      {:ok, _task} = RequestExecutor.async(fn -> raise "test error" end)
      # Should not crash - give it time to potentially crash
      Process.sleep(50)
      assert true
    end
  end

  describe "execute_all/2" do
    test "executes all functions and returns results in order" do
      funs = [
        fn -> 1 end,
        fn -> 2 end,
        fn -> 3 end
      ]

      results = RequestExecutor.execute_all(funs)

      assert [
               {:ok, 1},
               {:ok, 2},
               {:ok, 3}
             ] = results
    end

    test "handles mixed success and timeout" do
      funs = [
        fn -> :fast end,
        fn ->
          Process.sleep(200)
          :slow
        end,
        fn -> :also_fast end
      ]

      results = RequestExecutor.execute_all(funs, timeout: 50)

      assert [
               {:ok, :fast},
               {:error, :timeout},
               {:ok, :also_fast}
             ] = results
    end

    test "handles empty list" do
      results = RequestExecutor.execute_all([])
      assert [] = results
    end

    test "executes functions concurrently" do
      start_time = System.monotonic_time(:millisecond)

      # Three functions that each sleep for 100ms
      funs = [
        fn ->
          Process.sleep(100)
          1
        end,
        fn ->
          Process.sleep(100)
          2
        end,
        fn ->
          Process.sleep(100)
          3
        end
      ]

      results = RequestExecutor.execute_all(funs, timeout: 500)
      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should complete in ~100ms (concurrent), not 300ms (sequential)
      assert elapsed < 200
      assert length(results) == 3
    end
  end

  describe "supervisor/0" do
    test "returns the supervisor name" do
      assert RequestExecutor.supervisor() == Mydia.RequestTaskSupervisor
    end
  end
end
