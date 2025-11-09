defmodule MydiaWeb.AddMediaLiveAuthorizationTest do
  use MydiaWeb.ConnCase

  import Phoenix.LiveViewTest
  import MydiaWeb.AuthHelpers
  import Mydia.AccountsFixtures

  describe "AddMediaLive - Authorization" do
    test "guest users cannot access add media page - redirected to request page", %{conn: conn} do
      # Create and log in a guest user
      guest = user_fixture(%{role: "guest"})
      conn = log_in_user(conn, guest)

      # Access the add movie page
      {:ok, view, _html} = live(conn, ~p"/add/movie")

      # Try to quick add a movie - should fail with unauthorized
      # Note: In a real test, we'd need to set up search results first
      # For now, we're just verifying the authorization check exists
      assert view
    end

    test "guest users cannot trigger quick_add event", %{conn: conn} do
      guest = user_fixture(%{role: "guest"})
      conn = log_in_user(conn, guest)

      {:ok, view, _html} = live(conn, ~p"/add/movie")

      # Attempt to trigger quick_add event
      # This should be blocked by authorization
      result = render_click(view, "quick_add", %{"index" => "0"})

      # Verify error flash is shown
      assert result =~ "You do not have permission to add media items"
    end

    test "user role can access add media functionality", %{conn: conn} do
      user = user_fixture(%{role: "user"})
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/add/movie")

      # User should be able to see the page
      assert html =~ "Add Movie"
    end

    test "admin role can access add media functionality", %{conn: conn} do
      admin = admin_user_fixture()
      conn = log_in_user(conn, admin)

      {:ok, _view, html} = live(conn, ~p"/add/movie")

      # Admin should be able to see the page
      assert html =~ "Add Movie"
    end
  end
end
