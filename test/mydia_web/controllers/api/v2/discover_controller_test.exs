defmodule MydiaWeb.Api.V2.DiscoverControllerTest do
  use MydiaWeb.ConnCase, async: true

  alias Mydia.{Media, Playback}

  setup do
    # Create test user and get auth token
    {user, token} = MydiaWeb.AuthHelpers.create_user_and_token()

    {:ok, user: user, token: token}
  end

  describe "GET /api/v2/discover/continue" do
    test "returns empty list when no progress exists", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/discover/continue")

      assert json_response(conn, 200) == %{"data" => []}
    end

    test "returns in-progress movies sorted by last watched", %{
      conn: conn,
      token: token,
      user: user
    } do
      # Create two movies with progress
      {:ok, movie1} = create_media_item("movie", "Movie 1")
      {:ok, movie2} = create_media_item("movie", "Movie 2")

      # Add progress to movie1 (watched first, so older)
      {:ok, _} =
        Playback.save_progress(user.id, [media_item_id: movie1.id], %{
          position_seconds: 1000,
          duration_seconds: 5400
        })

      # Wait a moment to ensure different timestamps
      Process.sleep(10)

      # Add progress to movie2 (watched second, so newer)
      {:ok, _} =
        Playback.save_progress(user.id, [media_item_id: movie2.id], %{
          position_seconds: 2000,
          duration_seconds: 6000
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/discover/continue")

      response = json_response(conn, 200)
      items = response["data"]

      assert length(items) == 2
      # Most recently watched first (movie2)
      assert Enum.at(items, 0)["title"] == "Movie 2"
      assert Enum.at(items, 0)["type"] == "movie"
      assert Enum.at(items, 0)["progress"]["position_seconds"] == 2000
      # Older watch second (movie1)
      assert Enum.at(items, 1)["title"] == "Movie 1"
    end

    test "returns in-progress episodes sorted by last watched", %{
      conn: conn,
      token: token,
      user: user
    } do
      {:ok, episode1} = create_episode("Show 1", 1, 1)
      {:ok, episode2} = create_episode("Show 2", 1, 2)

      # Add progress to both episodes
      {:ok, _} =
        Playback.save_progress(user.id, [episode_id: episode1.id], %{
          position_seconds: 800,
          duration_seconds: 1800
        })

      Process.sleep(10)

      {:ok, _} =
        Playback.save_progress(user.id, [episode_id: episode2.id], %{
          position_seconds: 500,
          duration_seconds: 1800
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/discover/continue")

      response = json_response(conn, 200)
      items = response["data"]

      assert length(items) == 2
      # Most recent first
      assert Enum.at(items, 0)["type"] == "episode"
      assert Enum.at(items, 0)["show"]["title"] == "Show 2"
      assert Enum.at(items, 0)["season_number"] == 1
      assert Enum.at(items, 0)["episode_number"] == 2
    end

    test "excludes completed items (>= 90%)", %{conn: conn, token: token, user: user} do
      {:ok, movie1} = create_media_item("movie", "Movie 1")
      {:ok, movie2} = create_media_item("movie", "Movie 2")

      # movie1: 50% complete (should appear)
      {:ok, _} =
        Playback.save_progress(user.id, [media_item_id: movie1.id], %{
          position_seconds: 2700,
          duration_seconds: 5400
        })

      # movie2: 95% complete (should NOT appear)
      {:ok, _} =
        Playback.save_progress(user.id, [media_item_id: movie2.id], %{
          position_seconds: 5200,
          duration_seconds: 5400
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/discover/continue")

      response = json_response(conn, 200)
      items = response["data"]

      assert length(items) == 1
      assert Enum.at(items, 0)["title"] == "Movie 1"
    end

    test "requires authentication", %{conn: conn} do
      conn = get(conn, "/api/v2/discover/continue")
      assert conn.status in [401, 302]
    end
  end

  describe "GET /api/v2/discover/recent" do
    test "returns recently added media items", %{conn: conn, token: token} do
      # Create a recent movie
      {:ok, movie} = create_media_item("movie", "Recent Movie")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/discover/recent")

      response = json_response(conn, 200)
      items = response["data"]

      assert length(items) >= 1
      movie_item = Enum.find(items, fn item -> item["title"] == "Recent Movie" end)
      assert movie_item != nil
      assert movie_item["type"] == "movie"
      assert movie_item["added_at"] != nil
    end

    test "respects days parameter", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/discover/recent?days=7")

      response = json_response(conn, 200)
      assert is_list(response["data"])
    end

    test "respects limit parameter", %{conn: conn, token: token} do
      # Create multiple items
      for i <- 1..5 do
        create_media_item("movie", "Movie #{i}")
      end

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/discover/recent?limit=3")

      response = json_response(conn, 200)
      items = response["data"]

      # Should return at most 3 items
      assert length(items) <= 3
    end

    test "includes progress data when available", %{conn: conn, token: token, user: user} do
      {:ok, movie} = create_media_item("movie", "Movie with Progress")

      {:ok, _} =
        Playback.save_progress(user.id, [media_item_id: movie.id], %{
          position_seconds: 1000,
          duration_seconds: 5400
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/discover/recent")

      response = json_response(conn, 200)
      items = response["data"]

      movie_item = Enum.find(items, fn item -> item["title"] == "Movie with Progress" end)
      assert movie_item != nil
      assert movie_item["progress"]["position_seconds"] == 1000
    end

    test "requires authentication", %{conn: conn} do
      conn = get(conn, "/api/v2/discover/recent")
      assert conn.status in [401, 302]
    end
  end

  describe "GET /api/v2/discover/up_next" do
    test "returns empty list when user has no progress", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/discover/up_next")

      assert json_response(conn, 200) == %{"data" => []}
    end

    test "returns next unwatched episode for show with progress", %{
      conn: conn,
      token: token,
      user: user
    } do
      # Create a TV show with multiple episodes
      {:ok, show} =
        Media.create_media_item(
          %{
            title: "Test Show",
            tmdb_id: System.unique_integer([:positive]),
            type: "tv_show",
            monitored: true
          },
          skip_episode_refresh: true
        )

      # Create episodes
      {:ok, ep1} =
        Media.create_episode(%{
          media_item_id: show.id,
          season_number: 1,
          episode_number: 1,
          title: "Episode 1",
          monitored: true
        })

      {:ok, ep2} =
        Media.create_episode(%{
          media_item_id: show.id,
          season_number: 1,
          episode_number: 2,
          title: "Episode 2",
          monitored: true
        })

      # Mark episode 1 as watched (95% complete)
      {:ok, _} =
        Playback.save_progress(user.id, [episode_id: ep1.id], %{
          position_seconds: 1700,
          duration_seconds: 1800
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/discover/up_next")

      response = json_response(conn, 200)
      items = response["data"]

      assert length(items) == 1
      item = Enum.at(items, 0)
      assert item["type"] == "episode"
      assert item["title"] == "Episode 2"
      assert item["season_number"] == 1
      assert item["episode_number"] == 2
      assert item["state"] == "next"
    end

    test "returns in-progress episode when not yet 90% complete", %{
      conn: conn,
      token: token,
      user: user
    } do
      {:ok, show} =
        Media.create_media_item(
          %{
            title: "Test Show",
            tmdb_id: System.unique_integer([:positive]),
            type: "tv_show",
            monitored: true
          },
          skip_episode_refresh: true
        )

      {:ok, ep1} =
        Media.create_episode(%{
          media_item_id: show.id,
          season_number: 1,
          episode_number: 1,
          title: "Episode 1",
          monitored: true
        })

      # Mark episode 1 as partially watched (50%)
      {:ok, _} =
        Playback.save_progress(user.id, [episode_id: ep1.id], %{
          position_seconds: 900,
          duration_seconds: 1800
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/discover/up_next")

      response = json_response(conn, 200)
      items = response["data"]

      assert length(items) == 1
      item = Enum.at(items, 0)
      assert item["type"] == "episode"
      assert item["title"] == "Episode 1"
      assert item["state"] == "continue"
      assert item["progress"]["position_seconds"] == 900
    end

    test "respects limit parameter", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v2/discover/up_next?limit=5")

      response = json_response(conn, 200)
      items = response["data"]

      # Should respect the limit
      assert length(items) <= 5
    end

    test "requires authentication", %{conn: conn} do
      conn = get(conn, "/api/v2/discover/up_next")
      assert conn.status in [401, 302]
    end
  end

  # Helper functions
  defp create_media_item(type, title) do
    Media.create_media_item(%{
      title: title,
      tmdb_id: System.unique_integer([:positive]),
      type: type,
      year: 2024,
      monitored: true,
      metadata: %{
        "poster_path" => "/poster.jpg",
        "backdrop_path" => "/backdrop.jpg",
        "overview" => "Test overview"
      }
    })
  end

  defp create_episode(show_title, season_num, episode_num) do
    {:ok, show} =
      Media.create_media_item(
        %{
          title: show_title,
          tmdb_id: System.unique_integer([:positive]),
          type: "tv_show",
          monitored: true,
          metadata: %{
            "poster_path" => "/poster.jpg",
            "backdrop_path" => "/backdrop.jpg"
          }
        },
        skip_episode_refresh: true
      )

    Media.create_episode(%{
      media_item_id: show.id,
      season_number: season_num,
      episode_number: episode_num,
      title: "Episode #{season_num}x#{episode_num}",
      monitored: true,
      metadata: %{
        "still_path" => "/still.jpg",
        "overview" => "Episode overview"
      }
    })
  end
end
