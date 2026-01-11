defmodule MetadataRelay.TurnServerTest do
  use ExUnit.Case, async: false

  alias MetadataRelay.TurnServer

  @test_secret "test-secret-key-12345"

  describe "enabled?/0" do
    test "returns false when TURN_ENABLED is not set" do
      System.delete_env("TURN_ENABLED")
      refute TurnServer.enabled?()
    end

    test "returns false when TURN_ENABLED is not 'true'" do
      System.put_env("TURN_ENABLED", "false")
      refute TurnServer.enabled?()
      System.delete_env("TURN_ENABLED")
    end

    test "returns true when TURN_ENABLED is 'true'" do
      System.put_env("TURN_ENABLED", "true")
      assert TurnServer.enabled?()
      System.delete_env("TURN_ENABLED")
    end
  end

  describe "credential validation" do
    setup do
      # Start the TURN server with a test configuration
      System.put_env("TURN_SECRET", @test_secret)

      start_supervised!({TurnServer, [
        secret: @test_secret,
        port: 13478,
        listen_ip: {127, 0, 0, 1}
      ]})

      on_exit(fn ->
        System.delete_env("TURN_SECRET")
        System.delete_env("TURN_ENABLED")
      end)

      :ok
    end

    test "validates correct time-limited credentials" do
      # Generate a valid credential (expires in 1 hour)
      timestamp = System.os_time(:second) + 3600
      username = "#{timestamp}:test-user"
      password = :crypto.mac(:hmac, :sha, @test_secret, username) |> Base.encode64()

      assert {:ok, ^username} = TurnServer.validate_credential(username, password)
    end

    test "rejects expired credentials" do
      # Generate an expired credential (1 hour in the past)
      timestamp = System.os_time(:second) - 3600
      username = "#{timestamp}:test-user"
      password = :crypto.mac(:hmac, :sha, @test_secret, username) |> Base.encode64()

      assert {:error, :expired} = TurnServer.validate_credential(username, password)
    end

    test "rejects invalid password" do
      timestamp = System.os_time(:second) + 3600
      username = "#{timestamp}:test-user"
      wrong_password = "wrong-password"

      assert {:error, :invalid_password} = TurnServer.validate_credential(username, wrong_password)
    end

    test "rejects invalid username format" do
      assert {:error, :invalid_username_format} = TurnServer.validate_credential("no-timestamp", "pass")
    end

    test "rejects non-numeric timestamp" do
      assert {:error, :invalid_timestamp} = TurnServer.validate_credential("abc:user", "pass")
    end
  end

  describe "get_config/0" do
    setup do
      System.put_env("TURN_SECRET", @test_secret)

      start_supervised!({TurnServer, [
        secret: @test_secret,
        port: 13479,
        realm: "test-realm",
        listen_ip: {127, 0, 0, 1},
        min_port: 50000,
        max_port: 50100
      ]})

      on_exit(fn ->
        System.delete_env("TURN_SECRET")
      end)

      :ok
    end

    test "returns configuration" do
      config = TurnServer.get_config()

      assert config.port == 13479
      assert config.realm == "test-realm"
      assert config.min_port == 50000
      assert config.max_port == 50100
      assert config.listen_ip == {127, 0, 0, 1}
    end
  end
end
