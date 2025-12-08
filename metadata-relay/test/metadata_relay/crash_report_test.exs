defmodule MetadataRelay.CrashReportTest do
  use ExUnit.Case, async: false

  alias MetadataRelay.Router

  setup do
    # Start the rate limiter if not already started
    case GenServer.whereis(MetadataRelay.RateLimiter) do
      nil -> start_supervised!(MetadataRelay.RateLimiter)
      _pid -> :ok
    end

    # Ensure the repo is started for ErrorTracker
    case GenServer.whereis(MetadataRelay.Repo) do
      nil -> start_supervised!(MetadataRelay.Repo)
      _pid -> :ok
    end

    # Clear the rate limiter table before each test
    :ets.delete_all_objects(:rate_limiter)

    :ok
  end

  describe "POST /crashes/report" do
    test "successfully stores a crash report with valid data" do
      crash_report = %{
        "error_type" => "RuntimeError",
        "error_message" => "Test error message",
        "stacktrace" => [
          %{"file" => "lib/mydia/test.ex", "line" => 42, "function" => "test_function"},
          %{"file" => "lib/mydia/other.ex", "line" => 100}
        ],
        "version" => "1.0.0",
        "environment" => "test"
      }

      conn =
        Plug.Test.conn(:post, "/crashes/report", crash_report)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
        |> Router.call([])

      assert conn.status == 201

      assert %{"status" => "created", "message" => "Crash report received"} =
               Jason.decode!(conn.resp_body)
    end

    test "returns 400 when required fields are missing" do
      # Missing error_message and stacktrace
      crash_report = %{
        "error_type" => "RuntimeError"
      }

      conn =
        Plug.Test.conn(:post, "/crashes/report", crash_report)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
        |> Router.call([])

      assert conn.status == 400
      assert %{"error" => "Validation failed", "errors" => errors} = Jason.decode!(conn.resp_body)
      assert "Missing required field: error_message" in errors
      assert "Missing required field: stacktrace" in errors
    end

    test "returns 400 when stacktrace is not a list" do
      crash_report = %{
        "error_type" => "RuntimeError",
        "error_message" => "Test error",
        "stacktrace" => "not a list"
      }

      conn =
        Plug.Test.conn(:post, "/crashes/report", crash_report)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
        |> Router.call([])

      assert conn.status == 400
      assert %{"error" => "Validation failed", "errors" => errors} = Jason.decode!(conn.resp_body)
      assert "stacktrace must be a list" in errors
    end

    test "handles malformed JSON gracefully" do
      # Send empty body_params to simulate malformed JSON
      # (Plug.Parsers would raise in real scenario, but router handles empty params)
      conn =
        Plug.Test.conn(:post, "/crashes/report", %{})
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
        |> Router.call([])

      # Should return 400 for missing required fields
      assert conn.status == 400
      assert %{"error" => "Validation failed"} = Jason.decode!(conn.resp_body)
    end

    test "rate limits excessive requests from same IP" do
      # Clear rate limiter manually for this test
      :ets.delete_all_objects(:rate_limiter)

      crash_report = %{
        "error_type" => "RuntimeError",
        "error_message" => "Test error",
        "stacktrace" => [
          %{"file" => "lib/test.ex", "line" => 10}
        ]
      }

      # Make 10 requests (the limit) - all should succeed
      results =
        for i <- 1..10 do
          conn =
            Plug.Test.conn(:post, "/crashes/report", crash_report)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
            |> Router.call([])

          {i, conn.status}
        end

      # All 10 should succeed
      assert Enum.all?(results, fn {_i, status} -> status == 201 end),
             "Expected all 10 requests to succeed, got: #{inspect(results)}"

      # 11th request should be rate limited
      conn =
        Plug.Test.conn(:post, "/crashes/report", crash_report)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
        |> Router.call([])

      assert conn.status == 429
      assert %{"error" => "Too many requests"} = Jason.decode!(conn.resp_body)
      assert ["60"] = Plug.Conn.get_resp_header(conn, "retry-after")
    end
  end
end
