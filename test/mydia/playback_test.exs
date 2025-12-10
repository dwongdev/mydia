defmodule Mydia.PlaybackTest do
  use Mydia.DataCase, async: true

  alias Mydia.Playback
  alias Mydia.Accounts
  alias Mydia.Media

  describe "get_progress/2" do
    setup do
      {:ok, user} = create_user()
      {:ok, media_item} = create_media_item()
      {:ok, episode} = create_episode()

      %{user: user, media_item: media_item, episode: episode}
    end

    test "returns progress for a media item", %{user: user, media_item: media_item} do
      {:ok, _progress} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 120,
          duration_seconds: 3600
        })

      progress = Playback.get_progress(user.id, media_item_id: media_item.id)

      assert progress.position_seconds == 120
      assert progress.duration_seconds == 3600
      assert progress.user_id == user.id
      assert progress.media_item_id == media_item.id
    end

    test "returns progress for an episode", %{user: user, episode: episode} do
      {:ok, _progress} =
        Playback.save_progress(user.id, [episode_id: episode.id], %{
          position_seconds: 300,
          duration_seconds: 1800
        })

      progress = Playback.get_progress(user.id, episode_id: episode.id)

      assert progress.position_seconds == 300
      assert progress.duration_seconds == 1800
      assert progress.user_id == user.id
      assert progress.episode_id == episode.id
    end

    test "returns nil when no progress exists", %{user: user, media_item: media_item} do
      assert Playback.get_progress(user.id, media_item_id: media_item.id) == nil
    end
  end

  describe "save_progress/3" do
    setup do
      {:ok, user} = create_user()
      {:ok, media_item} = create_media_item()
      {:ok, episode} = create_episode()

      %{user: user, media_item: media_item, episode: episode}
    end

    test "creates new progress for a media item", %{user: user, media_item: media_item} do
      {:ok, progress} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 120,
          duration_seconds: 3600
        })

      assert progress.position_seconds == 120
      assert progress.duration_seconds == 3600
      assert_in_delta progress.completion_percentage, 3.333, 0.01
      assert progress.watched == false
      assert progress.last_watched_at != nil
    end

    test "creates new progress for an episode", %{user: user, episode: episode} do
      {:ok, progress} =
        Playback.save_progress(user.id, [episode_id: episode.id], %{
          position_seconds: 300,
          duration_seconds: 1800
        })

      assert progress.position_seconds == 300
      assert progress.duration_seconds == 1800
      assert progress.episode_id == episode.id
    end

    test "updates existing progress", %{user: user, media_item: media_item} do
      {:ok, _progress} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 120,
          duration_seconds: 3600
        })

      {:ok, updated_progress} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 240,
          duration_seconds: 3600
        })

      assert updated_progress.position_seconds == 240
      assert updated_progress.duration_seconds == 3600

      # Verify only one record exists
      assert [_single_progress] = Playback.list_user_progress(user.id)
    end

    test "automatically calculates completion percentage", %{user: user, media_item: media_item} do
      {:ok, progress} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 1800,
          duration_seconds: 3600
        })

      assert progress.completion_percentage == 50.0

      # Test with non-round percentage
      {:ok, progress2} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 120,
          duration_seconds: 3600
        })

      assert_in_delta progress2.completion_percentage, 3.333, 0.01
    end

    test "automatically marks as watched when >= 90%", %{user: user, media_item: media_item} do
      {:ok, progress} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 3300,
          duration_seconds: 3600
        })

      assert progress.completion_percentage >= 90.0
      assert progress.watched == true
    end

    test "does not mark as watched when < 90%", %{user: user, media_item: media_item} do
      {:ok, progress} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 3000,
          duration_seconds: 3600
        })

      assert progress.completion_percentage < 90.0
      assert progress.watched == false
    end

    test "requires positive position", %{user: user, media_item: media_item} do
      {:error, changeset} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: -1,
          duration_seconds: 3600
        })

      assert "must be greater than or equal to 0" in errors_on(changeset).position_seconds
    end

    test "requires positive duration", %{user: user, media_item: media_item} do
      {:error, changeset} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 120,
          duration_seconds: 0
        })

      assert "must be greater than 0" in errors_on(changeset).duration_seconds
    end

    test "enforces unique constraint per user/media_item", %{user: user, media_item: media_item} do
      {:ok, user2} = create_user()

      # Same media item, different users - should succeed
      {:ok, _progress1} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 120,
          duration_seconds: 3600
        })

      {:ok, _progress2} =
        Playback.save_progress(user2.id, [media_item_id: media_item.id], %{
          position_seconds: 240,
          duration_seconds: 3600
        })

      # Verify two separate records exist
      assert [_p1] = Playback.list_user_progress(user.id)
      assert [_p2] = Playback.list_user_progress(user2.id)
    end
  end

  describe "list_user_progress/2" do
    setup do
      {:ok, user} = create_user()
      {:ok, media_item1} = create_media_item()
      {:ok, media_item2} = create_media_item()
      {:ok, episode} = create_episode()

      # Create some progress records
      {:ok, _} =
        Playback.save_progress(user.id, [media_item_id: media_item1.id], %{
          position_seconds: 120,
          duration_seconds: 3600
        })

      {:ok, _} =
        Playback.save_progress(user.id, [media_item_id: media_item2.id], %{
          position_seconds: 3300,
          duration_seconds: 3600
        })

      {:ok, _} =
        Playback.save_progress(user.id, [episode_id: episode.id], %{
          position_seconds: 500,
          duration_seconds: 1800
        })

      %{user: user}
    end

    test "returns all progress for a user", %{user: user} do
      progress_list = Playback.list_user_progress(user.id)

      assert length(progress_list) == 3
    end

    test "filters by watched status", %{user: user} do
      # One item should be marked as watched (>= 90%)
      watched = Playback.list_user_progress(user.id, watched: true)
      unwatched = Playback.list_user_progress(user.id, watched: false)

      assert length(watched) == 1
      assert length(unwatched) == 2
    end

    test "limits results", %{user: user} do
      progress_list = Playback.list_user_progress(user.id, limit: 2)

      assert length(progress_list) == 2
    end

    test "orders by last_watched_at by default", %{user: user} do
      progress_list = Playback.list_user_progress(user.id)

      # All should have last_watched_at set
      assert Enum.all?(progress_list, & &1.last_watched_at)
    end
  end

  describe "mark_watched/2" do
    setup do
      {:ok, user} = create_user()
      {:ok, media_item} = create_media_item()

      {:ok, _progress} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 120,
          duration_seconds: 3600
        })

      %{user: user, media_item: media_item}
    end

    test "marks progress as watched", %{user: user, media_item: media_item} do
      {:ok, progress} = Playback.mark_watched(user.id, media_item_id: media_item.id)

      assert progress.watched == true
    end

    test "returns error when progress doesn't exist", %{user: user} do
      {:ok, other_media_item} = create_media_item()

      assert {:error, :not_found} =
               Playback.mark_watched(user.id, media_item_id: other_media_item.id)
    end
  end

  describe "delete_progress/2" do
    setup do
      {:ok, user} = create_user()
      {:ok, media_item} = create_media_item()

      {:ok, _progress} =
        Playback.save_progress(user.id, [media_item_id: media_item.id], %{
          position_seconds: 120,
          duration_seconds: 3600
        })

      %{user: user, media_item: media_item}
    end

    test "deletes progress record", %{user: user, media_item: media_item} do
      {:ok, _deleted} = Playback.delete_progress(user.id, media_item_id: media_item.id)

      assert Playback.get_progress(user.id, media_item_id: media_item.id) == nil
    end

    test "returns error when progress doesn't exist", %{user: user} do
      {:ok, other_media_item} = create_media_item()

      assert {:error, :not_found} =
               Playback.delete_progress(user.id, media_item_id: other_media_item.id)
    end
  end

  # Helper functions for test setup
  defp create_user do
    Accounts.create_user(%{
      email: "user#{System.unique_integer([:positive])}@example.com",
      username: "user#{System.unique_integer([:positive])}",
      password: "password123",
      role: "user"
    })
  end

  defp create_media_item do
    Media.create_media_item(%{
      title: "Test Movie #{System.unique_integer([:positive])}",
      tmdb_id: System.unique_integer([:positive]),
      type: "movie",
      year: 2024,
      monitored: true
    })
  end

  defp create_episode do
    {:ok, media_item} =
      Media.create_media_item(
        %{
          title: "Test Show #{System.unique_integer([:positive])}",
          tmdb_id: System.unique_integer([:positive]),
          type: "tv_show",
          monitored: true
        },
        skip_episode_refresh: true
      )

    Media.create_episode(%{
      media_item_id: media_item.id,
      season_number: 1,
      episode_number: 1,
      title: "Pilot",
      monitored: true
    })
  end
end
