defmodule MetadataRelay.RelayRateLimitTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias MetadataRelay.Relay
  alias MetadataRelay.Repo
  alias MetadataRelay.Router

  setup do
    # Use sandbox mode for database isolation
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    # Start rate limiter if not already started
    case GenServer.whereis(MetadataRelay.RateLimiter) do
      nil -> MetadataRelay.RateLimiter.start_link([])
      _pid -> :ok
    end

    # Clear the rate limiter ETS table before each test
    :ets.delete_all_objects(:rate_limiter)

    :ok
  end

  describe "POST /relay/instances rate limiting" do
    test "allows requests within limit" do
      public_key = :crypto.strong_rand_bytes(32) |> Base.encode64()

      body = %{
        "instance_id" => "test-#{System.unique_integer()}",
        "public_key" => public_key,
        "direct_urls" => []
      }

      # First 10 requests should succeed
      for i <- 1..10 do
        conn =
          build_conn(:post, "/relay/instances", body)
          |> put_req_header("content-type", "application/json")

        conn = Router.call(conn, [])

        assert conn.status == 200,
               "Request #{i} should succeed, got status #{conn.status}"
      end
    end

    test "blocks requests exceeding limit" do
      public_key = :crypto.strong_rand_bytes(32) |> Base.encode64()

      body = %{
        "instance_id" => "test-#{System.unique_integer()}",
        "public_key" => public_key,
        "direct_urls" => []
      }

      # Make 10 requests to hit the limit
      for _i <- 1..10 do
        conn =
          build_conn(:post, "/relay/instances", body)
          |> put_req_header("content-type", "application/json")

        Router.call(conn, [])
      end

      # 11th request should be rate limited
      conn =
        build_conn(:post, "/relay/instances", body)
        |> put_req_header("content-type", "application/json")

      conn = Router.call(conn, [])

      assert conn.status == 429
      assert get_resp_header(conn, "retry-after") == ["60"]

      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "rate_limited"
      assert body["retry_after"] == 60
    end

    test "rate limits per IP address" do
      public_key = :crypto.strong_rand_bytes(32) |> Base.encode64()

      body = %{
        "instance_id" => "test-#{System.unique_integer()}",
        "public_key" => public_key,
        "direct_urls" => []
      }

      # Make 10 requests from first IP
      for _i <- 1..10 do
        conn =
          build_conn(:post, "/relay/instances", body, "192.168.1.1")
          |> put_req_header("content-type", "application/json")

        Router.call(conn, [])
      end

      # Request from second IP should still work
      conn =
        build_conn(:post, "/relay/instances", body, "192.168.1.2")
        |> put_req_header("content-type", "application/json")

      conn = Router.call(conn, [])

      assert conn.status == 200
    end
  end

  describe "POST /relay/claim/:code rate limiting" do
    setup do
      # Create an instance with a claim code
      {:ok, instance} = create_instance()
      {:ok, _} = Relay.set_online(instance)
      {:ok, claim} = Relay.create_claim(instance, "user-1")

      {:ok, claim: claim}
    end

    test "allows requests within limit", %{claim: claim} do
      # First 5 requests should succeed
      for i <- 1..5 do
        conn =
          build_conn(:post, "/relay/claim/#{claim.code}", %{})
          |> put_req_header("content-type", "application/json")

        conn = Router.call(conn, [])

        assert conn.status == 200,
               "Request #{i} should succeed, got status #{conn.status}"
      end
    end

    test "blocks requests exceeding limit (5/min)", %{claim: claim} do
      # Make 5 requests to hit the limit
      for _i <- 1..5 do
        conn =
          build_conn(:post, "/relay/claim/#{claim.code}", %{})
          |> put_req_header("content-type", "application/json")

        Router.call(conn, [])
      end

      # 6th request should be rate limited
      conn =
        build_conn(:post, "/relay/claim/#{claim.code}", %{})
        |> put_req_header("content-type", "application/json")

      conn = Router.call(conn, [])

      assert conn.status == 429
      assert get_resp_header(conn, "retry-after") == ["60"]

      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "rate_limited"
    end
  end

  describe "GET /relay/instances/:id/connect rate limiting" do
    setup do
      {:ok, instance} = create_instance()
      {:ok, _} = Relay.set_online(instance)

      {:ok, instance: instance}
    end

    test "allows requests within limit", %{instance: instance} do
      # First 30 requests should succeed
      for i <- 1..30 do
        conn = build_conn(:get, "/relay/instances/#{instance.instance_id}/connect", nil)
        conn = Router.call(conn, [])

        assert conn.status == 200,
               "Request #{i} should succeed, got status #{conn.status}"
      end
    end

    test "blocks requests exceeding limit (30/min)", %{instance: instance} do
      # Make 30 requests to hit the limit
      for i <- 1..30 do
        conn = build_conn(:get, "/relay/instances/#{instance.instance_id}/connect", nil)
        conn = Router.call(conn, [])

        assert conn.status == 200,
               "Request #{i} should succeed, got status #{conn.status}"
      end

      # 31st request should be rate limited
      conn = build_conn(:get, "/relay/instances/#{instance.instance_id}/connect", nil)
      conn = Router.call(conn, [])

      assert conn.status == 429
      assert get_resp_header(conn, "retry-after") == ["60"]

      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "rate_limited"
    end
  end

  describe "rate limit response format" do
    test "includes retry-after header" do
      public_key = :crypto.strong_rand_bytes(32) |> Base.encode64()

      body = %{
        "instance_id" => "test-#{System.unique_integer()}",
        "public_key" => public_key,
        "direct_urls" => []
      }

      # Hit the rate limit
      for _i <- 1..10 do
        conn =
          build_conn(:post, "/relay/instances", body)
          |> put_req_header("content-type", "application/json")

        Router.call(conn, [])
      end

      # Get rate limited response
      conn =
        build_conn(:post, "/relay/instances", body)
        |> put_req_header("content-type", "application/json")

      conn = Router.call(conn, [])

      # Verify response format
      assert conn.status == 429
      assert ["60"] = get_resp_header(conn, "retry-after")

      # Content-type may include charset
      [content_type] = get_resp_header(conn, "content-type")
      assert String.starts_with?(content_type, "application/json")

      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "rate_limited"
      assert body["message"] == "Too many requests. Please try again later."
      assert body["retry_after"] == 60
    end
  end

  # Helper functions

  defp create_instance(attrs \\ %{}) do
    default_attrs = %{
      instance_id: "test-instance-#{System.unique_integer()}",
      public_key: :crypto.strong_rand_bytes(32),
      direct_urls: []
    }

    Relay.register_instance(Map.merge(default_attrs, attrs))
  end

  defp build_conn(method, path, body, remote_ip \\ "127.0.0.1") do
    ip_tuple =
      remote_ip
      |> String.split(".")
      |> Enum.map(&String.to_integer/1)
      |> List.to_tuple()

    # Build a test connection
    conn = Plug.Test.conn(method, path, body)

    # Set remote_ip
    %{conn | remote_ip: ip_tuple}
  end
end
