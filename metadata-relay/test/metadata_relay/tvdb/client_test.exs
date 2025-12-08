defmodule MetadataRelay.TVDB.ClientTest do
  use ExUnit.Case, async: false

  alias MetadataRelay.TVDB.Auth
  alias MetadataRelay.TVDB.Client
  alias MetadataRelay.Test.TVDBHelpers

  @moduletag :tvdb

  setup do
    # Set a test API key to avoid the missing key error
    System.put_env("TVDB_API_KEY", "test_api_key_12345")

    on_exit(fn ->
      TVDBHelpers.clear_tvdb_adapter()
      System.delete_env("TVDB_API_KEY")
    end)

    :ok
  end

  describe "new/1" do
    setup do
      token = TVDBHelpers.create_test_token()
      TVDBHelpers.set_tvdb_adapter(TVDBHelpers.mock_auth_success(token))

      {:ok, auth_pid} = Auth.start_link(name: :test_client_auth)
      on_exit(fn -> if Process.alive?(auth_pid), do: GenServer.stop(auth_pid) end)

      {:ok, auth_pid: auth_pid, token: token}
    end

    test "returns a Req client with correct base URL", %{auth_pid: auth_pid} do
      assert {:ok, client} = Client.new(auth_server: auth_pid)
      assert client.options.base_url == "https://api4.thetvdb.com/v4"
    end

    test "includes bearer token in headers", %{auth_pid: auth_pid, token: token} do
      assert {:ok, client} = Client.new(auth_server: auth_pid)

      # Req stores headers as a map with list values
      assert Map.has_key?(client.headers, "authorization")
      expected_auth = "Bearer #{token}"
      assert [^expected_auth] = Map.get(client.headers, "authorization")
    end

    test "includes JSON content-type headers", %{auth_pid: auth_pid} do
      assert {:ok, client} = Client.new(auth_server: auth_pid)

      # Req stores headers as a map with list values
      assert Map.get(client.headers, "accept") == ["application/json"]
      assert Map.get(client.headers, "content-type") == ["application/json"]
    end
  end

  describe "get/2" do
    setup do
      token = TVDBHelpers.create_test_token()

      # Set up adapter that handles both auth and API requests
      adapter =
        TVDBHelpers.mock_adapter_with_routes(%{
          "/v4/login" => {200, %{"data" => %{"token" => token}}},
          "/v4/search" => {200, %{"data" => [%{"id" => 123, "name" => "Test Show"}]}},
          "/v4/series/123" => {200, %{"data" => %{"id" => 123, "name" => "Test Series"}}}
        })

      TVDBHelpers.set_tvdb_adapter(adapter)

      {:ok, auth_pid} = Auth.start_link(name: :test_client_get_auth)
      on_exit(fn -> if Process.alive?(auth_pid), do: GenServer.stop(auth_pid) end)

      {:ok, auth_pid: auth_pid}
    end

    test "returns successful response for search", %{auth_pid: auth_pid} do
      assert {:ok, body} = Client.get("/search", auth_server: auth_pid, params: [query: "test"])
      assert %{"data" => [%{"id" => 123, "name" => "Test Show"}]} = body
    end

    test "returns successful response for series by ID", %{auth_pid: auth_pid} do
      assert {:ok, body} = Client.get("/series/123", auth_server: auth_pid)
      assert %{"data" => %{"id" => 123, "name" => "Test Series"}} = body
    end

    test "passes query parameters correctly", %{auth_pid: auth_pid} do
      # The mock adapter handles any URL containing /v4/search
      assert {:ok, _body} =
               Client.get("/search", auth_server: auth_pid, params: [query: "test", year: "2024"])
    end
  end

  describe "get/2 error handling" do
    setup do
      token = TVDBHelpers.create_test_token()
      TVDBHelpers.set_tvdb_adapter(TVDBHelpers.mock_auth_success(token))

      {:ok, auth_pid} = Auth.start_link(name: :test_client_error_auth)
      on_exit(fn -> if Process.alive?(auth_pid), do: GenServer.stop(auth_pid) end)

      {:ok, auth_pid: auth_pid, token: token}
    end

    test "handles 404 not found", %{auth_pid: auth_pid, token: token} do
      adapter =
        TVDBHelpers.mock_adapter_with_routes(%{
          "/v4/login" => {200, %{"data" => %{"token" => token}}},
          "/v4/series/999999" => {404, %{"error" => "Not found"}}
        })

      TVDBHelpers.set_tvdb_adapter(adapter)

      assert {:error, {:http_error, 404, %{"error" => "Not found"}}} =
               Client.get("/series/999999", auth_server: auth_pid)
    end

    test "handles 500 server error", %{auth_pid: auth_pid, token: token} do
      adapter =
        TVDBHelpers.mock_adapter_with_routes(%{
          "/v4/login" => {200, %{"data" => %{"token" => token}}},
          "/v4/series/123" => {500, %{"error" => "Internal Server Error"}}
        })

      TVDBHelpers.set_tvdb_adapter(adapter)

      assert {:error, {:http_error, 500, %{"error" => "Internal Server Error"}}} =
               Client.get("/series/123", auth_server: auth_pid)
    end

    test "handles rate limiting (429)", %{auth_pid: auth_pid, token: token} do
      adapter =
        TVDBHelpers.mock_adapter_with_routes(%{
          "/v4/login" => {200, %{"data" => %{"token" => token}}},
          "/v4/search" => {429, %{"error" => "Too Many Requests"}}
        })

      TVDBHelpers.set_tvdb_adapter(adapter)

      assert {:error, {:http_error, 429, %{"error" => "Too Many Requests"}}} =
               Client.get("/search", auth_server: auth_pid, params: [query: "test"])
    end
  end

  describe "get/2 with 401 token refresh" do
    test "refreshes token on 401 and retries" do
      token = TVDBHelpers.create_test_token()
      new_token = TVDBHelpers.create_test_token()

      # Track request count
      request_count = :counters.new(1, [:atomics])

      adapter = fn request ->
        count = :counters.add(request_count, 1, 1)
        url = request.url |> URI.to_string()

        cond do
          String.contains?(url, "/v4/login") ->
            # Return new token on refresh
            if count > 1 do
              {request, Req.Response.new(status: 200, body: %{"data" => %{"token" => new_token}})}
            else
              {request, Req.Response.new(status: 200, body: %{"data" => %{"token" => token}})}
            end

          String.contains?(url, "/v4/search") ->
            # First API call returns 401, subsequent ones succeed
            if :counters.get(request_count, 1) <= 2 do
              {request, Req.Response.new(status: 401, body: %{"error" => "Unauthorized"})}
            else
              {request, Req.Response.new(status: 200, body: %{"data" => []})}
            end

          true ->
            {request, Req.Response.new(status: 404, body: %{"error" => "Not found"})}
        end
      end

      System.put_env("TVDB_API_KEY", "test_key")
      TVDBHelpers.set_tvdb_adapter(adapter)

      {:ok, auth_pid} = Auth.start_link(name: :test_client_refresh_auth)

      # This should trigger a token refresh and retry
      result = Client.get("/search", auth_server: auth_pid, params: [query: "test"])

      # Clean up
      GenServer.stop(auth_pid)

      # The request should eventually succeed after token refresh
      assert {:ok, %{"data" => []}} = result
    end

    test "returns authentication error when refresh fails" do
      token = TVDBHelpers.create_test_token()

      # Track request count
      request_count = :counters.new(1, [:atomics])

      adapter = fn request ->
        :counters.add(request_count, 1, 1)
        url = request.url |> URI.to_string()

        cond do
          String.contains?(url, "/v4/login") ->
            count = :counters.get(request_count, 1)

            if count <= 1 do
              {request, Req.Response.new(status: 200, body: %{"data" => %{"token" => token}})}
            else
              # Token refresh fails
              {request, Req.Response.new(status: 401, body: %{"error" => "Invalid API key"})}
            end

          String.contains?(url, "/v4/search") ->
            # Always return 401
            {request, Req.Response.new(status: 401, body: %{"error" => "Unauthorized"})}

          true ->
            {request, Req.Response.new(status: 404, body: %{"error" => "Not found"})}
        end
      end

      System.put_env("TVDB_API_KEY", "test_key")
      TVDBHelpers.set_tvdb_adapter(adapter)

      {:ok, auth_pid} = Auth.start_link(name: :test_client_refresh_fail_auth)

      # This should fail after token refresh fails
      result = Client.get("/search", auth_server: auth_pid, params: [query: "test"])

      # Clean up
      GenServer.stop(auth_pid)

      # Should return authentication failed error
      assert {:error, {:authentication_failed, {:http_error, 401, _}}} = result
    end
  end

  describe "get/2 with different status codes" do
    setup do
      token = TVDBHelpers.create_test_token()
      TVDBHelpers.set_tvdb_adapter(TVDBHelpers.mock_auth_success(token))

      {:ok, auth_pid} = Auth.start_link(name: :test_client_status_auth)
      on_exit(fn -> if Process.alive?(auth_pid), do: GenServer.stop(auth_pid) end)

      {:ok, auth_pid: auth_pid, token: token}
    end

    test "handles 200 OK", %{auth_pid: auth_pid, token: token} do
      adapter =
        TVDBHelpers.mock_adapter_with_routes(%{
          "/v4/login" => {200, %{"data" => %{"token" => token}}},
          "/v4/test" => {200, %{"status" => "ok"}}
        })

      TVDBHelpers.set_tvdb_adapter(adapter)

      assert {:ok, %{"status" => "ok"}} = Client.get("/test", auth_server: auth_pid)
    end

    test "handles 201 Created", %{auth_pid: auth_pid, token: token} do
      adapter =
        TVDBHelpers.mock_adapter_with_routes(%{
          "/v4/login" => {200, %{"data" => %{"token" => token}}},
          "/v4/test" => {201, %{"status" => "created"}}
        })

      TVDBHelpers.set_tvdb_adapter(adapter)

      assert {:ok, %{"status" => "created"}} = Client.get("/test", auth_server: auth_pid)
    end

    test "handles 204 No Content", %{auth_pid: auth_pid, token: token} do
      adapter =
        TVDBHelpers.mock_adapter_with_routes(%{
          "/v4/login" => {200, %{"data" => %{"token" => token}}},
          "/v4/test" => {204, nil}
        })

      TVDBHelpers.set_tvdb_adapter(adapter)

      # 204 should still be considered success
      assert {:ok, nil} = Client.get("/test", auth_server: auth_pid)
    end

    test "handles 400 Bad Request", %{auth_pid: auth_pid, token: token} do
      adapter =
        TVDBHelpers.mock_adapter_with_routes(%{
          "/v4/login" => {200, %{"data" => %{"token" => token}}},
          "/v4/test" => {400, %{"error" => "Bad Request"}}
        })

      TVDBHelpers.set_tvdb_adapter(adapter)

      assert {:error, {:http_error, 400, %{"error" => "Bad Request"}}} =
               Client.get("/test", auth_server: auth_pid)
    end

    test "handles 403 Forbidden", %{auth_pid: auth_pid, token: token} do
      adapter =
        TVDBHelpers.mock_adapter_with_routes(%{
          "/v4/login" => {200, %{"data" => %{"token" => token}}},
          "/v4/test" => {403, %{"error" => "Forbidden"}}
        })

      TVDBHelpers.set_tvdb_adapter(adapter)

      assert {:error, {:http_error, 403, %{"error" => "Forbidden"}}} =
               Client.get("/test", auth_server: auth_pid)
    end
  end
end
