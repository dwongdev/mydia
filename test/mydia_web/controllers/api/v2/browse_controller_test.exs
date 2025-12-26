defmodule MydiaWeb.Api.V2.BrowseControllerTest do
  use MydiaWeb.ConnCase, async: true

  alias Mydia.{Media, Playback}

  setup do
    # Create test user and get auth token
    {user, token} = MydiaWeb.AuthHelpers.create_user_and_token()

    {:ok, user: user, token: token}
  end

  describe "GET /api/v2/browse/movies" do
    test "returns empty list when no movies exist", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/browse/movies")

      response = json_response(conn, 200)
      assert response["data"] == []
      assert response["pagination"]["total"] == 0
    end

    test "returns paginated list of movies", %{conn: conn, token: token} do
      # Create test movies
      {:ok, movie1} = create_movie("The Matrix", 1999, ["Action", "Sci-Fi"])
      {:ok, movie2} = create_movie("Inception", 2010, ["Action", "Thriller"])
      {:ok, _tv_show} = create_tv_show("Breaking Bad", 2008)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/browse/movies")

      response = json_response(conn, 200)
      assert length(response["data"]) == 2
      assert response["pagination"]["total"] == 2
      assert response["pagination"]["page"] == 1
      assert response["pagination"]["per_page"] == 20

      # Verify movie data structure
      movie_data = Enum.find(response["data"], &(&1["title"] == "The Matrix"))
      assert movie_data["id"] == movie1.id
      assert movie_data["year"] == 1999
      assert movie_data["genres"] == ["Action", "Sci-Fi"]
      assert Map.has_key?(movie_data, "poster_url")
      assert Map.has_key?(movie_data, "progress")
    end

    test "supports pagination params", %{conn: conn, token: token} do
      # Create 25 movies
      for i <- 1..25 do
        create_movie("Movie #{i}", 2000 + i, ["Action"])
      end

      # Get first page
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/browse/movies?page=1&per_page=10")

      response = json_response(conn, 200)
      assert length(response["data"]) == 10
      assert response["pagination"]["page"] == 1
      assert response["pagination"]["per_page"] == 10
      assert response["pagination"]["total"] == 25
      assert response["pagination"]["total_pages"] == 3

      # Get second page
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/browse/movies?page=2&per_page=10")

      response = json_response(conn, 200)
      assert length(response["data"]) == 10
      assert response["pagination"]["page"] == 2
    end

    test "supports year filtering", %{conn: conn, token: token} do
      {:ok, _movie1} = create_movie("Old Movie", 1999, [])
      {:ok, movie2} = create_movie("New Movie", 2020, [])

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/browse/movies?filter[year]=2020")

      response = json_response(conn, 200)
      assert length(response["data"]) == 1
      assert hd(response["data"])["id"] == movie2.id
    end

    test "supports sorting by title", %{conn: conn, token: token} do
      {:ok, _movie1} = create_movie("Zebra Movie", 2020, [])
      {:ok, movie2} = create_movie("Alpha Movie", 2020, [])

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/browse/movies?sort=title&order=asc")

      response = json_response(conn, 200)
      assert hd(response["data"])["id"] == movie2.id
    end

    test "includes watch progress for current user", %{conn: conn, token: token, user: user} do
      {:ok, movie} = create_movie("Test Movie", 2020, [])

      # Create progress for this user
      {:ok, _progress} =
        Playback.save_progress(user.id, [media_item_id: movie.id], %{
          position_seconds: 1000,
          duration_seconds: 5000
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/browse/movies")

      response = json_response(conn, 200)
      movie_data = hd(response["data"])
      assert movie_data["progress"]["position_seconds"] == 1000
      assert movie_data["progress"]["completion_percentage"] == 20.0
    end

    test "requires authentication", %{conn: conn} do
      conn = get(conn, "/api/v2/browse/movies")
      assert conn.status in [401, 302]
    end
  end

  describe "GET /api/v2/browse/movies/:id" do
    test "returns movie details", %{conn: conn, token: token} do
      {:ok, movie} = create_movie("The Matrix", 1999, ["Action", "Sci-Fi"])

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/browse/movies/#{movie.id}")

      response = json_response(conn, 200)
      movie_data = response["data"]
      assert movie_data["id"] == movie.id
      assert movie_data["title"] == "The Matrix"
      assert movie_data["year"] == 1999
      assert movie_data["genres"] == ["Action", "Sci-Fi"]
      assert is_list(movie_data["files"])
      assert Map.has_key?(movie_data, "progress")
    end

    test "returns 404 for non-existent movie", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/browse/movies/00000000-0000-0000-0000-000000000000")

      assert json_response(conn, 404)["error"] == "Movie not found"
    end

    test "returns 404 when media item is not a movie", %{conn: conn, token: token} do
      {:ok, tv_show} = create_tv_show("Breaking Bad", 2008)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/browse/movies/#{tv_show.id}")

      assert json_response(conn, 404)["error"] == "Media item is not a movie"
    end
  end

  describe "GET /api/v2/browse/tv" do
    test "returns empty list when no TV shows exist", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/browse/tv")

      response = json_response(conn, 200)
      assert response["data"] == []
      assert response["pagination"]["total"] == 0
    end

    test "returns paginated list of TV shows", %{conn: conn, token: token} do
      {:ok, show1} = create_tv_show("Breaking Bad", 2008)
      {:ok, _show2} = create_tv_show("The Wire", 2002)
      {:ok, _movie} = create_movie("The Matrix", 1999, [])

      # Create episodes for Breaking Bad
      create_episodes_for_show(show1.id, 1, 5)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/browse/tv")

      response = json_response(conn, 200)
      assert length(response["data"]) == 2
      assert response["pagination"]["total"] == 2

      # Verify show data structure
      show_data = Enum.find(response["data"], &(&1["title"] == "Breaking Bad"))
      assert show_data["id"] == show1.id
      assert show_data["year"] == 2008
      assert show_data["total_episodes"] == 5
      assert show_data["watched_episodes"] == 0
      assert Map.has_key?(show_data, "total_seasons")
    end

    test "includes episode watch count", %{conn: conn, token: token, user: user} do
      {:ok, show} = create_tv_show("Test Show", 2020)
      episodes = create_episodes_for_show(show.id, 1, 3)

      # Mark first episode as watched
      first_episode = hd(episodes)

      {:ok, _progress} =
        Playback.save_progress(user.id, [episode_id: first_episode.id], %{
          position_seconds: 2500,
          duration_seconds: 2500
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/browse/tv")

      response = json_response(conn, 200)
      show_data = hd(response["data"])
      assert show_data["total_episodes"] == 3
      assert show_data["watched_episodes"] == 1
    end
  end

  describe "GET /api/v2/browse/tv/:id" do
    test "returns TV show details with seasons summary", %{conn: conn, token: token} do
      {:ok, show} = create_tv_show("Breaking Bad", 2008)
      create_episodes_for_show(show.id, 1, 7)
      create_episodes_for_show(show.id, 2, 13)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/browse/tv/#{show.id}")

      response = json_response(conn, 200)
      show_data = response["data"]
      assert show_data["id"] == show.id
      assert show_data["title"] == "Breaking Bad"
      assert is_list(show_data["seasons"])
      assert length(show_data["seasons"]) == 2

      # Verify season 1 summary
      season1 = Enum.find(show_data["seasons"], &(&1["season_number"] == 1))
      assert season1["episode_count"] == 7
      assert season1["watched_count"] == 0

      # Verify season 2 summary
      season2 = Enum.find(show_data["seasons"], &(&1["season_number"] == 2))
      assert season2["episode_count"] == 13
    end

    test "returns 404 for non-existent TV show", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/browse/tv/00000000-0000-0000-0000-000000000000")

      assert json_response(conn, 404)["error"] == "TV show not found"
    end
  end

  describe "GET /api/v2/browse/tv/:id/seasons/:season" do
    test "returns episode list for season", %{conn: conn, token: token} do
      {:ok, show} = create_tv_show("Test Show", 2020)
      episodes = create_episodes_for_show(show.id, 1, 5)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/browse/tv/#{show.id}/seasons/1")

      response = json_response(conn, 200)
      data = response["data"]
      assert data["media_item_id"] == show.id
      assert data["season_number"] == 1
      assert length(data["episodes"]) == 5

      # Verify episode structure
      episode_data = hd(data["episodes"])
      first_episode = hd(episodes)
      assert episode_data["id"] == first_episode.id
      assert episode_data["season_number"] == 1
      assert episode_data["episode_number"] == 1
      assert is_list(episode_data["files"])
      assert Map.has_key?(episode_data, "progress")
    end

    test "includes episode watch progress", %{conn: conn, token: token, user: user} do
      {:ok, show} = create_tv_show("Test Show", 2020)
      episodes = create_episodes_for_show(show.id, 1, 3)

      # Mark first episode with progress
      first_episode = hd(episodes)

      {:ok, _progress} =
        Playback.save_progress(user.id, [episode_id: first_episode.id], %{
          position_seconds: 500,
          duration_seconds: 2000
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/browse/tv/#{show.id}/seasons/1")

      response = json_response(conn, 200)
      episodes_data = response["data"]["episodes"]
      first_ep_data = Enum.find(episodes_data, &(&1["episode_number"] == 1))
      assert first_ep_data["progress"]["position_seconds"] == 500
      assert first_ep_data["progress"]["completion_percentage"] == 25.0
    end

    test "returns 404 for non-existent season", %{conn: conn, token: token} do
      {:ok, show} = create_tv_show("Test Show", 2020)
      create_episodes_for_show(show.id, 1, 5)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/browse/tv/#{show.id}/seasons/99")

      assert json_response(conn, 404)["error"] == "Season not found"
    end

    test "returns 400 for invalid season number", %{conn: conn, token: token} do
      {:ok, show} = create_tv_show("Test Show", 2020)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/browse/tv/#{show.id}/seasons/invalid")

      assert json_response(conn, 400)["error"] == "Invalid season number"
    end
  end

  # Helper functions for test setup
  defp create_movie(title, year, genres) do
    Media.create_media_item(%{
      title: title,
      tmdb_id: System.unique_integer([:positive]),
      type: "movie",
      year: year,
      monitored: true,
      genres: genres
    })
  end

  defp create_tv_show(title, year) do
    Media.create_media_item(
      %{
        title: title,
        tmdb_id: System.unique_integer([:positive]),
        type: "tv_show",
        year: year,
        monitored: true
      },
      skip_episode_refresh: true
    )
  end

  defp create_episodes_for_show(media_item_id, season_number, count) do
    for episode_number <- 1..count do
      {:ok, episode} =
        Media.create_episode(%{
          media_item_id: media_item_id,
          season_number: season_number,
          episode_number: episode_number,
          title: "Episode #{episode_number}",
          monitored: true
        })

      episode
    end
  end
end
