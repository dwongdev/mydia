defmodule Mydia.MediaTest do
  use Mydia.DataCase

  alias Mydia.Media

  describe "media_items" do
    alias Mydia.Media.MediaItem

    import Mydia.MediaFixtures

    @invalid_attrs %{type: nil, title: nil}

    test "list_media_items/0 returns all media items" do
      media_item = media_item_fixture()
      assert Media.list_media_items() == [media_item]
    end

    test "get_media_item!/1 returns the media item with given id" do
      media_item = media_item_fixture()
      assert Media.get_media_item!(media_item.id) == media_item
    end

    test "create_media_item/1 with valid data creates a media item" do
      valid_attrs = %{
        type: "movie",
        title: "Test Movie",
        year: 2024,
        tmdb_id: 12345,
        monitored: true
      }

      assert {:ok, %MediaItem{} = media_item} = Media.create_media_item(valid_attrs)
      assert media_item.type == "movie"
      assert media_item.title == "Test Movie"
      assert media_item.year == 2024
      assert media_item.tmdb_id == 12345
      assert media_item.monitored == true
    end

    test "create_media_item/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Media.create_media_item(@invalid_attrs)
    end

    test "create_media_item/1 requires year for movies" do
      attrs_without_year = %{
        type: "movie",
        title: "Test Movie",
        tmdb_id: 12345,
        monitored: true
      }

      assert {:error, %Ecto.Changeset{} = changeset} =
               Media.create_media_item(attrs_without_year)

      assert %{year: ["is required for movies"]} = errors_on(changeset)
    end

    test "create_media_item/1 allows tv_shows without year" do
      attrs_without_year = %{
        type: "tv_show",
        title: "Test Show",
        tmdb_id: 12345,
        monitored: true
      }

      assert {:ok, %MediaItem{} = media_item} = Media.create_media_item(attrs_without_year)
      assert media_item.type == "tv_show"
      assert media_item.title == "Test Show"
      assert media_item.year == nil
    end

    test "update_media_item/2 with valid data updates the media item" do
      media_item = media_item_fixture()
      update_attrs = %{title: "Updated Title", monitored: false}

      assert {:ok, %MediaItem{} = media_item} =
               Media.update_media_item(media_item, update_attrs)

      assert media_item.title == "Updated Title"
      assert media_item.monitored == false
    end

    test "delete_media_item/1 deletes the media item" do
      media_item = media_item_fixture()
      assert {:ok, %MediaItem{}} = Media.delete_media_item(media_item)
      assert_raise Ecto.NoResultsError, fn -> Media.get_media_item!(media_item.id) end
    end

    test "change_media_item/1 returns a media item changeset" do
      media_item = media_item_fixture()
      assert %Ecto.Changeset{} = Media.change_media_item(media_item)
    end
  end

  describe "episodes" do
    alias Mydia.Media.Episode

    import Mydia.MediaFixtures

    @invalid_attrs %{season_number: nil, episode_number: nil}

    test "list_episodes/1 returns all episodes for a media item" do
      media_item = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(media_item_id: media_item.id)
      assert Media.list_episodes(media_item.id) == [episode]
    end

    test "get_episode!/1 returns the episode with given id" do
      media_item = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(media_item_id: media_item.id)
      assert Media.get_episode!(episode.id) == episode
    end

    test "create_episode/1 with valid data creates an episode" do
      media_item = media_item_fixture(%{type: "tv_show"})

      valid_attrs = %{
        media_item_id: media_item.id,
        season_number: 1,
        episode_number: 1,
        title: "Pilot"
      }

      assert {:ok, %Episode{} = episode} = Media.create_episode(valid_attrs)
      assert episode.season_number == 1
      assert episode.episode_number == 1
      assert episode.title == "Pilot"
    end

    test "create_episode/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Media.create_episode(@invalid_attrs)
    end

    test "update_episode/2 with valid data updates the episode" do
      media_item = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(media_item_id: media_item.id)
      update_attrs = %{title: "Updated Episode Title"}

      assert {:ok, %Episode{} = episode} = Media.update_episode(episode, update_attrs)
      assert episode.title == "Updated Episode Title"
    end

    test "delete_episode/1 deletes the episode" do
      media_item = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(media_item_id: media_item.id)
      assert {:ok, %Episode{}} = Media.delete_episode(episode)
      assert_raise Ecto.NoResultsError, fn -> Media.get_episode!(episode.id) end
    end
  end

  describe "category classification" do
    alias Mydia.Media.MediaItem

    import Mydia.MediaFixtures

    test "create_media_item/1 auto-classifies movies without animation genre" do
      attrs = %{
        type: "movie",
        title: "Regular Movie",
        year: 2024,
        metadata: %{genres: ["Drama", "Action"]}
      }

      assert {:ok, %MediaItem{} = media_item} = Media.create_media_item(attrs)
      assert media_item.category == "movie"
      assert media_item.category_override == false
    end

    test "create_media_item/1 auto-classifies anime movies" do
      attrs = %{
        type: "movie",
        title: "Anime Movie",
        year: 2024,
        metadata: %{
          genres: ["Animation", "Adventure"],
          origin_country: ["JP"],
          original_language: "ja"
        }
      }

      assert {:ok, %MediaItem{} = media_item} = Media.create_media_item(attrs)
      assert media_item.category == "anime_movie"
    end

    test "create_media_item/1 auto-classifies cartoon movies" do
      attrs = %{
        type: "movie",
        title: "Cartoon Movie",
        year: 2024,
        metadata: %{
          genres: ["Animation", "Family"],
          origin_country: ["US"],
          original_language: "en"
        }
      }

      assert {:ok, %MediaItem{} = media_item} = Media.create_media_item(attrs)
      assert media_item.category == "cartoon_movie"
    end

    test "create_media_item/1 auto-classifies TV shows" do
      attrs = %{
        type: "tv_show",
        title: "Regular TV Show",
        metadata: %{genres: ["Drama"]}
      }

      assert {:ok, %MediaItem{} = media_item} = Media.create_media_item(attrs)
      assert media_item.category == "tv_show"
    end

    test "create_media_item/1 auto-classifies anime series" do
      attrs = %{
        type: "tv_show",
        title: "Anime Series",
        metadata: %{
          genres: ["Animation", "Action"],
          origin_country: ["JP"]
        }
      }

      assert {:ok, %MediaItem{} = media_item} = Media.create_media_item(attrs)
      assert media_item.category == "anime_series"
    end

    test "create_media_item/1 auto-classifies cartoon series" do
      attrs = %{
        type: "tv_show",
        title: "Cartoon Series",
        metadata: %{
          genres: ["Animation", "Comedy"],
          origin_country: ["US"]
        }
      }

      assert {:ok, %MediaItem{} = media_item} = Media.create_media_item(attrs)
      assert media_item.category == "cartoon_series"
    end

    test "update_category/2 updates the category" do
      media_item = media_item_fixture()

      assert {:ok, %MediaItem{} = updated} = Media.update_category(media_item, :anime_movie)
      assert updated.category == "anime_movie"
      assert updated.category_override == false
    end

    test "update_category/3 with override: true sets the override flag" do
      media_item = media_item_fixture()

      assert {:ok, %MediaItem{} = updated} =
               Media.update_category(media_item, :anime_movie, override: true)

      assert updated.category == "anime_movie"
      assert updated.category_override == true
    end

    test "clear_category_override/1 clears the override flag" do
      media_item = media_item_fixture()
      {:ok, media_item} = Media.update_category(media_item, :anime_movie, override: true)

      assert media_item.category_override == true

      assert {:ok, %MediaItem{} = updated} = Media.clear_category_override(media_item)
      assert updated.category_override == false
    end

    test "reclassify_media_item/1 reclassifies based on metadata" do
      # Create a movie that gets classified as regular movie
      attrs = %{
        type: "movie",
        title: "Test Movie",
        year: 2024,
        metadata: %{genres: ["Drama"]}
      }

      {:ok, media_item} = Media.create_media_item(attrs)
      assert media_item.category == "movie"

      # Update metadata to make it anime
      {:ok, media_item} =
        Media.update_media_item(media_item, %{
          metadata: %{
            genres: ["Animation"],
            origin_country: ["JP"],
            original_language: "ja"
          }
        })

      # Reclassify
      assert {:ok, %MediaItem{} = reclassified} = Media.reclassify_media_item(media_item)
      assert reclassified.category == "anime_movie"
    end

    test "reclassify_media_item/1 respects category_override flag" do
      media_item = media_item_fixture()
      {:ok, media_item} = Media.update_category(media_item, :cartoon_movie, override: true)

      # Update metadata to indicate anime
      {:ok, media_item} =
        Media.update_media_item(media_item, %{
          metadata: %{genres: ["Animation"], origin_country: ["JP"]}
        })

      # Reclassify should NOT change the category
      assert {:ok, %MediaItem{} = unchanged} = Media.reclassify_media_item(media_item)
      assert unchanged.category == "cartoon_movie"
    end

    test "reclassify_media_item/2 with force: true ignores override" do
      media_item = media_item_fixture()
      {:ok, media_item} = Media.update_category(media_item, :cartoon_movie, override: true)

      # Update metadata to indicate anime
      {:ok, media_item} =
        Media.update_media_item(media_item, %{
          metadata: %{genres: ["Animation"], origin_country: ["JP"]}
        })

      # Reclassify with force should change the category
      assert {:ok, %MediaItem{} = forced} = Media.reclassify_media_item(media_item, force: true)
      assert forced.category == "anime_movie"
    end

    test "list_media_items/1 filters by category" do
      # Create movies with different categories
      {:ok, movie} =
        Media.create_media_item(%{
          type: "movie",
          title: "Regular Movie",
          year: 2024,
          metadata: %{genres: ["Drama"]}
        })

      {:ok, anime} =
        Media.create_media_item(%{
          type: "movie",
          title: "Anime Movie",
          year: 2024,
          metadata: %{genres: ["Animation"], origin_country: ["JP"]}
        })

      # Filter by category (atom)
      movies = Media.list_media_items(category: :movie)
      assert length(movies) == 1
      assert hd(movies).id == movie.id

      # Filter by category (string)
      anime_movies = Media.list_media_items(category: "anime_movie")
      assert length(anime_movies) == 1
      assert hd(anime_movies).id == anime.id
    end

    test "reclassify_all_media_items/0 reclassifies all non-override items" do
      # Create some items - they will be auto-classified
      {:ok, movie} =
        Media.create_media_item(%{
          type: "movie",
          title: "Test Movie 1",
          year: 2024,
          metadata: %{genres: ["Drama"]}
        })

      {:ok, _anime} =
        Media.create_media_item(%{
          type: "movie",
          title: "Test Movie 2",
          year: 2024,
          metadata: %{genres: ["Animation"], origin_country: ["JP"]}
        })

      # Set override on one
      {:ok, overridden} = Media.update_category(movie, :cartoon_movie, override: true)
      assert overridden.category_override == true

      # Reclassify all
      assert {:ok, count} = Media.reclassify_all_media_items()
      assert count >= 1

      # Overridden item should remain unchanged
      updated_movie = Media.get_media_item!(movie.id)
      assert updated_movie.category == "cartoon_movie"
    end

    test "reclassify_media_items/2 reclassifies selected items by ID" do
      # Create items with specific metadata
      {:ok, movie} =
        Media.create_media_item(%{
          type: "movie",
          title: "Regular Movie",
          year: 2024,
          metadata: %{genres: ["Drama"]}
        })

      {:ok, anime} =
        Media.create_media_item(%{
          type: "movie",
          title: "Anime Movie",
          year: 2024,
          metadata: %{genres: ["Animation"], origin_country: ["JP"]}
        })

      # Verify initial classifications
      assert movie.category == "movie"
      assert anime.category == "anime_movie"

      # Manually change anime to a wrong category (for testing re-classification)
      {:ok, _} = Media.update_category(anime, :movie)

      # Re-classify specific items
      {:ok, summary} = Media.reclassify_media_items([anime.id])

      assert summary.total == 1
      assert summary.updated == 1
      assert summary.skipped == 0
      assert summary.unchanged == 0

      # Verify it was reclassified correctly
      updated_anime = Media.get_media_item!(anime.id)
      assert updated_anime.category == "anime_movie"
    end

    test "reclassify_media_items/2 respects category_override flag" do
      {:ok, movie} =
        Media.create_media_item(%{
          type: "movie",
          title: "Overridden Movie",
          year: 2024,
          metadata: %{genres: ["Animation"], origin_country: ["JP"]}
        })

      # Should be classified as anime_movie
      assert movie.category == "anime_movie"

      # Set override to a different category
      {:ok, overridden} = Media.update_category(movie, :movie, override: true)
      assert overridden.category_override == true
      assert overridden.category == "movie"

      # Try to reclassify - should be skipped
      {:ok, summary} = Media.reclassify_media_items([movie.id])

      assert summary.total == 1
      assert summary.updated == 0
      assert summary.skipped == 1

      # Verify category unchanged
      still_overridden = Media.get_media_item!(movie.id)
      assert still_overridden.category == "movie"
    end

    test "reclassify_media_items/2 with force: true ignores override" do
      {:ok, movie} =
        Media.create_media_item(%{
          type: "movie",
          title: "Force Reclassify Movie",
          year: 2024,
          metadata: %{genres: ["Animation"], origin_country: ["JP"]}
        })

      # Set override to wrong category
      {:ok, overridden} = Media.update_category(movie, :movie, override: true)
      assert overridden.category == "movie"
      assert overridden.category_override == true

      # Force reclassify
      {:ok, summary} = Media.reclassify_media_items([movie.id], force: true)

      assert summary.updated == 1
      assert summary.skipped == 0

      # Verify it was reclassified
      updated = Media.get_media_item!(movie.id)
      assert updated.category == "anime_movie"
    end

    test "reclassify_media_items/2 returns correct summary with unchanged items" do
      {:ok, movie} =
        Media.create_media_item(%{
          type: "movie",
          title: "Already Correct Movie",
          year: 2024,
          metadata: %{genres: ["Drama"]}
        })

      # Verify it's already correctly classified
      assert movie.category == "movie"

      # Reclassify - should not change anything
      {:ok, summary} = Media.reclassify_media_items([movie.id])

      assert summary.total == 1
      assert summary.updated == 0
      assert summary.skipped == 0
      assert summary.unchanged == 1
    end
  end
end
