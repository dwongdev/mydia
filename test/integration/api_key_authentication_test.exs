defmodule Mydia.Integration.ApiKeyAuthenticationTest do
  use MydiaWeb.ConnCase

  alias Mydia.Accounts
  alias Mydia.AccountsFixtures

  describe "API key authentication via HTTP" do
    setup do
      # Reset rate limiter for test IP
      Mydia.Accounts.ApiKeyRateLimiter.reset_rate_limit("127.0.0.1")

      user = AccountsFixtures.user_fixture()
      {:ok, api_key_record, plain_key} = Accounts.create_api_key(user.id, %{name: "Test Key"})
      %{user: user, api_key_record: api_key_record, plain_key: plain_key}
    end

    test "authenticates with valid API key in header", %{plain_key: plain_key, user: user} do
      conn =
        build_conn()
        |> Mydia.Auth.Guardian.Plug.put_current_resource(nil)
        |> put_req_header("x-api-key", plain_key)
        |> MydiaWeb.Plugs.ApiAuth.call([])

      # Verify user is authenticated
      assert Mydia.Auth.Guardian.Plug.current_resource(conn) != nil
      assert Mydia.Auth.Guardian.Plug.current_resource(conn).id == user.id
    end

    test "authenticates with valid API key in query parameter", %{
      plain_key: plain_key,
      user: user
    } do
      conn =
        build_conn(:get, "/?api_key=#{plain_key}")
        |> Mydia.Auth.Guardian.Plug.put_current_resource(nil)
        |> Plug.Conn.fetch_query_params()
        |> MydiaWeb.Plugs.ApiAuth.call([])

      # Verify user is authenticated
      assert Mydia.Auth.Guardian.Plug.current_resource(conn) != nil
      assert Mydia.Auth.Guardian.Plug.current_resource(conn).id == user.id
    end

    test "rejects invalid API key" do
      conn =
        build_conn()
        |> put_req_header("x-api-key", "invalid_key")
        |> MydiaWeb.Plugs.ApiAuth.call([])

      assert conn.halted == true
      assert conn.status == 401
    end

    test "rejects revoked API key", %{plain_key: plain_key, api_key_record: api_key_record} do
      # Revoke the key
      {:ok, _} = Accounts.revoke_api_key(api_key_record)

      conn =
        build_conn()
        |> put_req_header("x-api-key", plain_key)
        |> MydiaWeb.Plugs.ApiAuth.call([])

      assert conn.halted == true
      assert conn.status == 401
    end

    test "rejects expired API key", %{user: user} do
      # Create an expired key
      expires_at = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)

      {:ok, _api_key_record, plain_key} =
        Accounts.create_api_key(user.id, %{name: "Expired Key", expires_at: expires_at})

      conn =
        build_conn()
        |> put_req_header("x-api-key", plain_key)
        |> MydiaWeb.Plugs.ApiAuth.call([])

      assert conn.halted == true
      assert conn.status == 401
    end

    test "rate limits failed authentication attempts" do
      # Make 10 failed attempts
      for _i <- 1..10 do
        build_conn()
        |> put_req_header("x-api-key", "invalid_key_#{:rand.uniform(1000)}")
        |> MydiaWeb.Plugs.ApiAuth.call([])
      end

      # Next attempt should be rate limited
      conn =
        build_conn()
        |> put_req_header("x-api-key", "invalid_key")
        |> MydiaWeb.Plugs.ApiAuth.call([])

      assert conn.halted == true
      assert conn.status == 429
    end
  end

  describe "API key usage tracking" do
    setup do
      # Reset rate limiter for test IP
      Mydia.Accounts.ApiKeyRateLimiter.reset_rate_limit("127.0.0.1")

      user = AccountsFixtures.user_fixture()
      {:ok, api_key_record, plain_key} = Accounts.create_api_key(user.id, %{name: "Test Key"})
      %{user: user, api_key_record: api_key_record, plain_key: plain_key}
    end

    test "updates last_used_at timestamp on successful authentication", %{
      plain_key: plain_key,
      api_key_record: original_key
    } do
      # Initial last_used_at should be nil
      assert original_key.last_used_at == nil

      # Authenticate with the key
      build_conn()
      |> Mydia.Auth.Guardian.Plug.put_current_resource(nil)
      |> put_req_header("x-api-key", plain_key)
      |> MydiaWeb.Plugs.ApiAuth.call([])

      # Reload and verify timestamp was updated
      reloaded = Accounts.get_api_key!(original_key.id)
      assert reloaded.last_used_at != nil

      # Verify timestamp is recent
      now = DateTime.utc_now()
      diff = DateTime.diff(now, reloaded.last_used_at, :second)
      assert diff < 5
    end
  end
end
