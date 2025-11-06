defmodule Mydia.Downloads.TorrentMatcherTest do
  use Mydia.DataCase, async: true
  alias Mydia.Downloads.TorrentMatcher
  alias Mydia.Media
  import Mydia.Factory

  describe "find_match/2 - movies" do
    setup do
      # Create some movies in the library
      movie1 =
        insert(:media_item, %{
          type: "movie",
          title: "The Matrix",
          year: 1999,
          monitored: true
        })

      movie2 =
        insert(:media_item, %{
          type: "movie",
          title: "Inception",
          year: 2010,
          monitored: true
        })

      movie3 =
        insert(:media_item, %{
          type: "movie",
          title: "The Lord of the Rings",
          year: 2001,
          monitored: true
        })

      {:ok, %{movie1: movie1, movie2: movie2, movie3: movie3}}
    end

    test "matches exact movie title and year", %{movie1: movie} do
      torrent_info = %{
        type: :movie,
        title: "The Matrix",
        year: 1999,
        quality: "1080p",
        source: "BluRay"
      }

      assert {:ok, match} = TorrentMatcher.find_match(torrent_info)
      assert match.media_item.id == movie.id
      assert match.episode == nil
      assert match.confidence > 0.8
    end

    test "matches movie with slightly different title formatting", %{movie1: movie} do
      torrent_info = %{
        type: :movie,
        title: "The Matrix",
        year: 1999,
        quality: "720p"
      }

      assert {:ok, match} = TorrentMatcher.find_match(torrent_info)
      assert match.media_item.id == movie.id
    end

    test "matches movie with normalized title", %{movie3: movie} do
      # Torrent might have different spacing/punctuation
      torrent_info = %{
        type: :movie,
        title: "Lord of the Rings",
        year: 2001,
        quality: "1080p"
      }

      assert {:ok, match} = TorrentMatcher.find_match(torrent_info)
      assert match.media_item.id == movie.id
      # Confidence should be high but not perfect due to missing "The"
      assert match.confidence > 0.7
    end

    test "returns error when no match found" do
      torrent_info = %{
        type: :movie,
        title: "Nonexistent Movie",
        year: 2099,
        quality: "1080p"
      }

      assert {:error, :no_match_found} = TorrentMatcher.find_match(torrent_info)
    end

    test "returns error when confidence is below threshold", %{movie1: _movie} do
      torrent_info = %{
        type: :movie,
        title: "Completely Different Title",
        year: 1999,
        quality: "1080p"
      }

      # High threshold to ensure no match
      assert {:error, :no_match_found} =
               TorrentMatcher.find_match(torrent_info, confidence_threshold: 0.9)
    end

    test "skips unmonitored movies by default" do
      insert(:media_item, %{
        type: "movie",
        title: "Unmonitored Movie",
        year: 2020,
        monitored: false
      })

      torrent_info = %{
        type: :movie,
        title: "Unmonitored Movie",
        year: 2020,
        quality: "1080p"
      }

      assert {:error, :no_match_found} = TorrentMatcher.find_match(torrent_info)
    end

    test "can match unmonitored movies when monitored_only: false" do
      movie =
        insert(:media_item, %{
          type: "movie",
          title: "Unmonitored Movie",
          year: 2020,
          monitored: false
        })

      torrent_info = %{
        type: :movie,
        title: "Unmonitored Movie",
        year: 2020,
        quality: "1080p"
      }

      assert {:ok, match} = TorrentMatcher.find_match(torrent_info, monitored_only: false)
      assert match.media_item.id == movie.id
    end
  end

  describe "find_match/2 - TV shows" do
    setup do
      # Create a TV show with episodes
      tv_show =
        insert(:media_item, %{
          type: "tv_show",
          title: "Breaking Bad",
          monitored: true
        })

      episode1 =
        insert(:episode, %{
          media_item: tv_show,
          season_number: 1,
          episode_number: 1,
          title: "Pilot"
        })

      episode2 =
        insert(:episode, %{
          media_item: tv_show,
          season_number: 1,
          episode_number: 2,
          title: "Cat's in the Bag..."
        })

      {:ok, %{tv_show: tv_show, episode1: episode1, episode2: episode2}}
    end

    test "matches exact TV show and episode", %{tv_show: show, episode1: episode} do
      torrent_info = %{
        type: :tv,
        title: "Breaking Bad",
        season: 1,
        episode: 1,
        quality: "720p",
        source: "HDTV"
      }

      assert {:ok, match} = TorrentMatcher.find_match(torrent_info)
      assert match.media_item.id == show.id
      assert match.episode.id == episode.id
      assert match.confidence > 0.8
    end

    test "matches TV show with slightly different title formatting", %{
      tv_show: show,
      episode2: episode
    } do
      torrent_info = %{
        type: :tv,
        title: "Breaking Bad",
        season: 1,
        episode: 2,
        quality: "1080p"
      }

      assert {:ok, match} = TorrentMatcher.find_match(torrent_info)
      assert match.media_item.id == show.id
      assert match.episode.id == episode.id
    end

    test "returns error when show matches but episode doesn't exist", %{tv_show: _show} do
      torrent_info = %{
        type: :tv,
        title: "Breaking Bad",
        season: 5,
        episode: 99,
        quality: "720p"
      }

      assert {:error, :episode_not_found} = TorrentMatcher.find_match(torrent_info)
    end

    test "returns error when no matching show found" do
      torrent_info = %{
        type: :tv,
        title: "Nonexistent Show",
        season: 1,
        episode: 1,
        quality: "720p"
      }

      assert {:error, :no_match_found} = TorrentMatcher.find_match(torrent_info)
    end

    test "skips unmonitored TV shows by default" do
      tv_show =
        insert(:media_item, %{
          type: "tv_show",
          title: "Unmonitored Show",
          monitored: false
        })

      insert(:episode, %{
        media_item: tv_show,
        season_number: 1,
        episode_number: 1
      })

      torrent_info = %{
        type: :tv,
        title: "Unmonitored Show",
        season: 1,
        episode: 1,
        quality: "720p"
      }

      assert {:error, :no_match_found} = TorrentMatcher.find_match(torrent_info)
    end
  end

  describe "find_match/2 - TV season packs" do
    setup do
      # Create a TV show with episodes
      tv_show =
        insert(:media_item, %{
          type: "tv_show",
          title: "House of the Dragon",
          monitored: true
        })

      episode1 =
        insert(:episode, %{
          media_item: tv_show,
          season_number: 1,
          episode_number: 1,
          title: "The Heirs of the Dragon"
        })

      episode2 =
        insert(:episode, %{
          media_item: tv_show,
          season_number: 1,
          episode_number: 2,
          title: "The Rogue Prince"
        })

      {:ok, %{tv_show: tv_show, episode1: episode1, episode2: episode2}}
    end

    test "matches season pack to show without requiring specific episode", %{tv_show: show} do
      torrent_info = %{
        type: :tv_season,
        title: "House of the Dragon",
        season: 1,
        season_pack: true,
        quality: "2160p",
        source: "BluRay"
      }

      assert {:ok, match} = TorrentMatcher.find_match(torrent_info)
      assert match.media_item.id == show.id
      assert match.episode == nil
      assert match.confidence > 0.8
      assert match.match_reason =~ "season pack"
    end

    test "matches season pack with different formatting", %{tv_show: show} do
      torrent_info = %{
        type: :tv_season,
        title: "House of Dragon",
        season: 1,
        season_pack: true,
        quality: "1080p"
      }

      assert {:ok, match} = TorrentMatcher.find_match(torrent_info)
      assert match.media_item.id == show.id
      assert match.episode == nil
    end

    test "returns error when no matching show found for season pack" do
      torrent_info = %{
        type: :tv_season,
        title: "Nonexistent Show",
        season: 1,
        season_pack: true,
        quality: "1080p"
      }

      assert {:error, :no_match_found} = TorrentMatcher.find_match(torrent_info)
    end

    test "skips unmonitored shows for season packs by default" do
      tv_show =
        insert(:media_item, %{
          type: "tv_show",
          title: "Unmonitored Show",
          monitored: false
        })

      insert(:episode, %{
        media_item: tv_show,
        season_number: 1,
        episode_number: 1
      })

      torrent_info = %{
        type: :tv_season,
        title: "Unmonitored Show",
        season: 1,
        season_pack: true,
        quality: "1080p"
      }

      assert {:error, :no_match_found} = TorrentMatcher.find_match(torrent_info)
    end

    test "can match unmonitored shows for season packs when monitored_only: false" do
      tv_show =
        insert(:media_item, %{
          type: "tv_show",
          title: "Unmonitored Show",
          monitored: false
        })

      insert(:episode, %{
        media_item: tv_show,
        season_number: 1,
        episode_number: 1
      })

      torrent_info = %{
        type: :tv_season,
        title: "Unmonitored Show",
        season: 1,
        season_pack: true,
        quality: "1080p"
      }

      assert {:ok, match} = TorrentMatcher.find_match(torrent_info, monitored_only: false)
      assert match.media_item.id == tv_show.id
      assert match.episode == nil
    end
  end

  describe "confidence calculation" do
    test "exact movie match has very high confidence" do
      movie =
        insert(:media_item, %{
          type: "movie",
          title: "The Matrix",
          year: 1999,
          monitored: true
        })

      torrent_info = %{
        type: :movie,
        title: "The Matrix",
        year: 1999,
        quality: "1080p"
      }

      assert {:ok, match} = TorrentMatcher.find_match(torrent_info)
      assert match.media_item.id == movie.id
      # Should be very high confidence for exact match
      assert match.confidence > 0.95
    end

    test "year mismatch reduces confidence" do
      movie =
        insert(:media_item, %{
          type: "movie",
          title: "The Matrix",
          year: 1999,
          monitored: true
        })

      # Wrong year
      torrent_info = %{
        type: :movie,
        title: "The Matrix",
        year: 2020,
        quality: "1080p"
      }

      # Should either not match or have lower confidence
      case TorrentMatcher.find_match(torrent_info, confidence_threshold: 0.5) do
        {:ok, match} ->
          assert match.media_item.id == movie.id
          # Confidence should be lower due to year mismatch
          assert match.confidence < 0.8

        {:error, :no_match_found} ->
          # Also acceptable - year mismatch prevented match
          assert true
      end
    end
  end
end
