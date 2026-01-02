defmodule MydiaWeb.Schema.RemoteAccessTest do
  use MydiaWeb.ConnCase

  alias Mydia.Accounts
  alias Mydia.RemoteAccess.MediaToken
  alias Mydia.RemoteAccess.RemoteDevice
  alias Mydia.Repo

  @refresh_media_token_mutation """
  mutation RefreshMediaToken($token: String!) {
    refreshMediaToken(token: $token) {
      token
      expiresAt
      permissions
    }
  }
  """

  describe "refreshMediaToken mutation" do
    setup do
      user = create_user()
      device = create_device(user)
      {:ok, token, _claims} = MediaToken.create_token(device, permissions: ["stream", "download"])
      %{user: user, device: device, token: token}
    end

    test "refreshes a valid token", %{token: old_token} do
      variables = %{"token" => old_token}
      result = run_query(@refresh_media_token_mutation, variables)

      assert {:ok, %{data: %{"refreshMediaToken" => response}}} = result
      assert response["token"] != nil
      assert response["token"] != old_token
      assert response["expiresAt"] != nil
      assert response["permissions"] == ["stream", "download"]
    end

    test "returns error for invalid token" do
      variables = %{"token" => "invalid.jwt.token"}
      result = run_query(@refresh_media_token_mutation, variables)

      assert {:ok, %{errors: [%{message: message}]}} = result
      # Error could be "Invalid token", "Failed to refresh token", or similar
      assert message =~ "Invalid" or message =~ "invalid" or message =~ "Failed to refresh"
    end

    test "returns error for expired token", %{device: device} do
      # Create a short-lived token (1 second TTL)
      {:ok, expired_token, claims} = MediaToken.create_token(device, ttl: {1, :second})

      # Verify the TTL was applied (exp should be about 1 second after iat)
      assert claims["exp"] - claims["iat"] <= 2

      # Wait for token to expire (TTL + allowed_drift of 2 seconds + margin)
      Process.sleep(4000)

      variables = %{"token" => expired_token}
      result = run_query(@refresh_media_token_mutation, variables)

      assert {:ok, %{errors: [%{message: message}]}} = result
      assert message =~ "expired"
    end

    test "returns error for revoked device token", %{device: device, token: token} do
      # Revoke the device
      device
      |> RemoteDevice.revoke_changeset()
      |> Repo.update!()

      variables = %{"token" => token}
      result = run_query(@refresh_media_token_mutation, variables)

      assert {:ok, %{errors: [%{message: message}]}} = result
      assert message =~ "revoked"
    end

    test "preserves permissions when refreshing", %{device: device} do
      # Create token with limited permissions
      {:ok, token, _claims} = MediaToken.create_token(device, permissions: ["stream"])

      variables = %{"token" => token}
      result = run_query(@refresh_media_token_mutation, variables)

      assert {:ok, %{data: %{"refreshMediaToken" => response}}} = result
      assert response["permissions"] == ["stream"]
    end
  end

  # Helper function to run GraphQL queries (no auth needed for token refresh)
  defp run_query(query, variables) do
    Absinthe.run(query, MydiaWeb.Schema, variables: variables, context: %{})
  end

  # Test Helpers

  defp create_user(attrs \\ %{}) do
    default_attrs = %{
      email: "user-#{System.unique_integer([:positive])}@example.com",
      username: "user#{System.unique_integer([:positive])}",
      password: "password123",
      role: "user"
    }

    {:ok, user} =
      default_attrs
      |> Map.merge(attrs)
      |> Accounts.create_user()

    user
  end

  defp create_device(user, attrs \\ %{}) do
    # Generate a random 32-byte public key
    public_key = :crypto.strong_rand_bytes(32)

    default_attrs = %{
      device_name: "Test Device #{System.unique_integer([:positive])}",
      platform: "ios",
      device_static_public_key: public_key,
      token: "device-token-#{System.unique_integer([:positive])}",
      user_id: user.id
    }

    %RemoteDevice{}
    |> RemoteDevice.changeset(Map.merge(default_attrs, attrs))
    |> Repo.insert!()
  end
end
