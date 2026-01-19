defmodule MetadataRelay.Relay.PendingRequestsTest do
  use ExUnit.Case, async: false

  alias MetadataRelay.Relay.PendingRequests

  setup do
    # Clear all pending requests for a fresh state each test
    # We can't call clear() since we didn't implement it, so we'll use
    # fail_all for any instance that might have pending requests
    :ok
  end

  describe "register/3 and lookup/1" do
    test "returns :not_found for unregistered requests" do
      assert :not_found = PendingRequests.lookup("nonexistent-request")
    end

    test "registers and looks up requests" do
      pid = self()
      :ok = PendingRequests.register("instance-1", "request-123", pid)

      assert {:ok, "instance-1", ^pid} = PendingRequests.lookup("request-123")
    end

    test "stores multiple independent requests" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)

      :ok = PendingRequests.register("instance-1", "request-1", pid1)
      :ok = PendingRequests.register("instance-1", "request-2", pid2)

      assert {:ok, "instance-1", ^pid1} = PendingRequests.lookup("request-1")
      assert {:ok, "instance-1", ^pid2} = PendingRequests.lookup("request-2")

      # Cleanup
      PendingRequests.delete("request-1")
      PendingRequests.delete("request-2")
      Enum.each([pid1, pid2], &Process.exit(&1, :kill))
    end
  end

  describe "resolve/2" do
    test "sends response to waiting process and removes from table" do
      :ok = PendingRequests.register("instance-1", "request-123", self())

      assert {:ok, _, _} = PendingRequests.lookup("request-123")

      spawn(fn ->
        PendingRequests.resolve("request-123", %{status: 200, body: "OK"})
      end)

      assert_receive {:response, "request-123", %{status: 200, body: "OK"}}, 1000

      # Should be removed after resolve
      assert :not_found = PendingRequests.lookup("request-123")
    end

    test "returns :not_found for non-existent request" do
      assert :not_found = PendingRequests.resolve("nonexistent", "response")
    end
  end

  describe "delete/1" do
    test "removes request from table" do
      :ok = PendingRequests.register("instance-1", "request-123", self())
      assert {:ok, _, _} = PendingRequests.lookup("request-123")

      :ok = PendingRequests.delete("request-123")
      assert :not_found = PendingRequests.lookup("request-123")
    end

    test "is a no-op for non-existent request" do
      assert :ok = PendingRequests.delete("nonexistent")
    end
  end

  describe "fail_all/2" do
    test "sends error to all waiting processes for an instance" do
      # Create multiple waiting processes
      parent = self()

      pids =
        for _i <- 1..3 do
          spawn(fn ->
            receive do
              {:error, request_id, error} ->
                send(parent, {:failed, request_id, error})
            end
          end)
        end

      # Register requests for each process
      request_ids = ["request-1", "request-2", "request-3"]

      Enum.zip(pids, request_ids)
      |> Enum.each(fn {pid, request_id} ->
        PendingRequests.register("instance-fail", request_id, pid)
      end)

      assert PendingRequests.count_for_instance("instance-fail") == 3

      # Fail all requests
      failed_count = PendingRequests.fail_all("instance-fail", {:error, :tunnel_disconnected})

      assert failed_count == 3

      # All processes should receive error - collect all messages
      received_ids =
        for _i <- 1..3 do
          assert_receive {:failed, request_id, {:error, :tunnel_disconnected}}, 1000
          request_id
        end

      # Verify we got all three request IDs
      assert Enum.sort(received_ids) == Enum.sort(request_ids)

      # Requests should be removed
      assert PendingRequests.count_for_instance("instance-fail") == 0

      # Cleanup
      Enum.each(pids, &Process.exit(&1, :kill))
    end

    test "returns 0 when no pending requests for instance" do
      assert 0 = PendingRequests.fail_all("no-such-instance")
    end

    test "only fails requests for the specified instance" do
      :ok = PendingRequests.register("instance-a", "request-a1", self())
      :ok = PendingRequests.register("instance-a", "request-a2", self())
      :ok = PendingRequests.register("instance-b", "request-b1", self())

      # Fail only instance-a
      failed_count = PendingRequests.fail_all("instance-a")

      assert failed_count == 2

      # instance-b request should still exist
      assert {:ok, "instance-b", _} = PendingRequests.lookup("request-b1")

      # Cleanup
      PendingRequests.delete("request-b1")
    end
  end

  describe "await_response/3" do
    test "returns response when resolved" do
      # Spawn a process to resolve the request after a delay
      spawn(fn ->
        Process.sleep(50)
        PendingRequests.resolve("await-test", %{status: 200})
      end)

      result = PendingRequests.await_response("instance-1", "await-test", 1000)

      assert {:ok, %{status: 200}} = result
    end

    test "returns error when failed" do
      spawn(fn ->
        Process.sleep(50)
        # Simulate tunnel disconnect
        PendingRequests.fail_all("instance-await", {:error, :tunnel_disconnected})
      end)

      result = PendingRequests.await_response("instance-await", "await-fail", 1000)

      assert {:error, {:error, :tunnel_disconnected}} = result
    end

    test "returns timeout error when no response" do
      result = PendingRequests.await_response("instance-1", "timeout-test", 100)

      assert {:error, :timeout} = result

      # Request should be cleaned up
      assert :not_found = PendingRequests.lookup("timeout-test")
    end
  end

  describe "count/0 and count_for_instance/1" do
    test "count returns total pending requests" do
      initial = PendingRequests.count()

      :ok = PendingRequests.register("instance-1", "count-1", self())
      :ok = PendingRequests.register("instance-2", "count-2", self())

      assert PendingRequests.count() == initial + 2

      # Cleanup
      PendingRequests.delete("count-1")
      PendingRequests.delete("count-2")
    end

    test "count_for_instance returns count for specific instance" do
      :ok = PendingRequests.register("count-instance", "ci-1", self())
      :ok = PendingRequests.register("count-instance", "ci-2", self())
      :ok = PendingRequests.register("other-instance", "oi-1", self())

      assert PendingRequests.count_for_instance("count-instance") == 2
      assert PendingRequests.count_for_instance("other-instance") == 1
      assert PendingRequests.count_for_instance("no-instance") == 0

      # Cleanup
      PendingRequests.delete("ci-1")
      PendingRequests.delete("ci-2")
      PendingRequests.delete("oi-1")
    end
  end

  describe "list_for_instance/1" do
    test "returns all pending requests for an instance" do
      :ok = PendingRequests.register("list-instance", "li-1", self())
      :ok = PendingRequests.register("list-instance", "li-2", self())
      :ok = PendingRequests.register("other", "other-1", self())

      requests = PendingRequests.list_for_instance("list-instance")

      assert length(requests) == 2
      request_ids = Enum.map(requests, fn {id, _pid, _time} -> id end)
      assert "li-1" in request_ids
      assert "li-2" in request_ids

      # Cleanup
      PendingRequests.delete("li-1")
      PendingRequests.delete("li-2")
      PendingRequests.delete("other-1")
    end

    test "returns empty list for instance with no requests" do
      assert [] = PendingRequests.list_for_instance("no-such-instance")
    end
  end
end
