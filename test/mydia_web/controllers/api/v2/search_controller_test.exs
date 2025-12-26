defmodule MydiaWeb.Api.V2.SearchControllerTest do
  use MydiaWeb.ConnCase, async: true

  alias Mydia.Media

  setup do
    # Create test user and get auth token
    {user, token} = MydiaWeb.AuthHelpers.create_user_and_token()

    # Create test media items with various titles
    {:ok, movie1} =
      Media.create_media_item(%{
        type: "movie",
        title: "The Matrix",
        original_title: "The Matrix",
        year: 1999,
        metadata: %{"poster_path" => "https://example.com/matrix.jpg"}
      })

    {:ok, movie2} =
      Media.create_media_item(%{
        type: "movie",
        title: "The Matrix Reloaded",
        original_title: "The Matrix Reloaded",
        year: 2003,
        metadata: %{"poster_path" => "https://example.com/reloaded.jpg"}
      })

    {:ok, tv_show} =
      Media.create_media_item(%{
        type: "tv_show",
        title: "Breaking Bad",
        original_title: "Breaking Bad",
        metadata: %{"poster_path" => "https://example.com/bb.jpg"}
      })

    {:ok, movie_no_poster} =
      Media.create_media_item(%{
        type: "movie",
        title: "Indie Film",
        year: 2020,
        metadata: %{}
      })

    {:ok, movie_original_title} =
      Media.create_media_item(%{
        type: "movie",
        title: "Spirited Away",
        original_title: "Sen to Chihiro no Kamikakushi",
        year: 2001,
        metadata: %{}
      })

    {:ok,
     user: user,
     token: token,
     movie1: movie1,
     movie2: movie2,
     tv_show: tv_show,
     movie_no_poster: movie_no_poster,
     movie_original_title: movie_original_title}
  end

  describe "GET /api/v2/search" do
    test "searches by title and returns matching results", %{
      conn: conn,
      token: token,
      movie1: movie1,
      movie2: movie2
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/search?q=Matrix")

      response = json_response(conn, 200)

      assert response["total"] == 2
      assert length(response["results"]) == 2

      titles = Enum.map(response["results"], & &1["title"])
      assert "The Matrix" in titles
      assert "The Matrix Reloaded" in titles

      # Verify result structure
      result = Enum.find(response["results"], &(&1["title"] == "The Matrix"))
      assert result["id"] == movie1.id
      assert result["type"] == "movie"
      assert result["title"] == "The Matrix"
      assert result["original_title"] == "The Matrix"
      assert result["year"] == 1999
      assert result["poster_url"] == "https://example.com/matrix.jpg"
    end

    test "searches by original_title and returns matching results", %{
      conn: conn,
      token: token,
      movie_original_title: movie
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/search?q=Kamikakushi")

      response = json_response(conn, 200)

      assert response["total"] == 1
      assert length(response["results"]) == 1

      result = hd(response["results"])
      assert result["id"] == movie.id
      assert result["title"] == "Spirited Away"
      assert result["original_title"] == "Sen to Chihiro no Kamikakushi"
    end

    test "returns both movies and TV shows", %{
      conn: conn,
      token: token,
      tv_show: tv_show
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/search?q=Breaking")

      response = json_response(conn, 200)

      assert response["total"] == 1
      assert length(response["results"]) == 1

      result = hd(response["results"])
      assert result["id"] == tv_show.id
      assert result["type"] == "tv_show"
      assert result["title"] == "Breaking Bad"
    end

    test "returns empty results when no query provided", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/search?q=")

      response = json_response(conn, 200)

      assert response["total"] == 0
      assert response["results"] == []
    end

    test "returns empty results when no query parameter", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/search")

      response = json_response(conn, 200)

      assert response["total"] == 0
      assert response["results"] == []
    end

    test "returns empty results when no matches found", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/search?q=NonExistentMovie12345")

      response = json_response(conn, 200)

      assert response["total"] == 0
      assert response["results"] == []
    end

    test "search is case-insensitive", %{conn: conn, token: token, movie1: movie1} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/search?q=matrix")

      response = json_response(conn, 200)

      assert response["total"] >= 1
      result_ids = Enum.map(response["results"], & &1["id"])
      assert movie1.id in result_ids
    end

    test "handles poster_url being nil when no metadata", %{
      conn: conn,
      token: token,
      movie_no_poster: movie
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/search?q=Indie")

      response = json_response(conn, 200)

      assert response["total"] == 1

      result = hd(response["results"])
      assert result["id"] == movie.id
      assert result["poster_url"] == nil
    end

    test "respects default limit of 20 results", %{conn: conn, token: token} do
      # Create 25 movies with similar titles
      for i <- 1..25 do
        Media.create_media_item(%{
          type: "movie",
          title: "Test Movie #{i}",
          year: 2000 + i,
          metadata: %{}
        })
      end

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/search?q=Test")

      response = json_response(conn, 200)

      # Should return exactly 20 results (default limit)
      assert length(response["results"]) == 20
      assert response["total"] == 20
    end

    test "respects custom limit parameter", %{conn: conn, token: token} do
      # Create 10 movies
      for i <- 1..10 do
        Media.create_media_item(%{
          type: "movie",
          title: "Limited Movie #{i}",
          year: 2000 + i,
          metadata: %{}
        })
      end

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/search?q=Limited&limit=5")

      response = json_response(conn, 200)

      assert length(response["results"]) == 5
      assert response["total"] == 5
    end

    test "enforces maximum limit of 100", %{conn: conn, token: token} do
      # Create a few test movies
      for i <- 1..5 do
        Media.create_media_item(%{
          type: "movie",
          title: "Max Limit Movie #{i}",
          year: 2000 + i,
          metadata: %{}
        })
      end

      # Request with limit > 100
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/search?q=Max&limit=500")

      response = json_response(conn, 200)

      # Should cap at available results (5 in this case)
      assert length(response["results"]) == 5
    end

    test "handles invalid limit parameter gracefully", %{
      conn: conn,
      token: token,
      movie1: movie1
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/search?q=Matrix&limit=invalid")

      response = json_response(conn, 200)

      # Should use default limit and still return results
      assert response["total"] >= 1
      result_ids = Enum.map(response["results"], & &1["id"])
      assert movie1.id in result_ids
    end

    test "requires authentication", %{conn: conn} do
      conn = get(conn, "/api/v2/search?q=Matrix")

      # Should get 401 Unauthorized or redirect
      assert conn.status in [401, 302]
    end
  end
end
