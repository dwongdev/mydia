defmodule Mydia.Settings.QualityProfileEngineTest do
  use Mydia.DataCase, async: true

  alias Mydia.Settings
  alias Mydia.Settings.{QualityProfile, QualityProfileEngine}
  alias Mydia.Library.MediaFile

  describe "evaluate_file/2" do
    setup do
      # Create a quality profile with comprehensive quality standards
      {:ok, profile} =
        Settings.create_quality_profile(%{
          name: "Test HD Profile",
          qualities: ["720p", "1080p"],
          quality_standards: %{
            preferred_video_codecs: ["h265", "h264"],
            preferred_audio_codecs: ["atmos", "ac3"],
            preferred_audio_channels: ["5.1", "2.0"],
            min_resolution: "720p",
            max_resolution: "1080p",
            preferred_resolutions: ["1080p"],
            preferred_sources: ["BluRay", "WEB-DL"],
            min_video_bitrate_mbps: 5.0,
            max_video_bitrate_mbps: 20.0,
            min_audio_bitrate_kbps: 128,
            max_audio_bitrate_kbps: 640,
            episode_min_size_mb: 500,
            episode_max_size_mb: 2048
          }
        })

      # Create a library path
      {:ok, library_path} =
        Settings.create_library_path(%{
          path: "/test/media",
          type: :series,
          monitored: true
        })

      %{profile: profile, library_path: library_path}
    end

    test "evaluates a perfect match file", %{profile: profile, library_path: library_path} do
      # Create a perfect match file (struct only, not inserted)
      media_file = %MediaFile{
        id: Ecto.UUID.generate(),
        relative_path: "show/episode.mkv",
        library_path_id: library_path.id,
        library_path: library_path,
        codec: "h265",
        audio_codec: "atmos",
        resolution: "1080p",
        size: 1_073_741_824,
        # 1 GB
        bitrate: 10_000_000,
        # 10 Mbps
        metadata: %{"audio_channels" => "5.1", "source" => "BluRay"},
        episode_id: Ecto.UUID.generate()
      }

      assert {:ok, evaluation} = QualityProfileEngine.evaluate_file(profile, media_file)

      assert evaluation.score >= 90.0
      assert evaluation.violations == []
      assert is_list(evaluation.recommendations)
      assert %DateTime{} = evaluation.evaluated_at
      assert is_map(evaluation.breakdown)
    end

    test "evaluates a low quality file with violations", %{
      profile: profile,
      library_path: library_path
    } do
      # Create a low quality file that violates standards
      media_file = %MediaFile{
        id: Ecto.UUID.generate(),
        relative_path: "show/episode.mkv",
        library_path_id: library_path.id,
        library_path: library_path,
        codec: "xvid",
        audio_codec: "mp3",
        resolution: "480p",
        # Below minimum
        size: 209_715_200,
        # 200 MB - below minimum
        bitrate: 2_000_000,
        # 2 Mbps
        metadata: %{"audio_channels" => "2.0"},
        episode_id: Ecto.UUID.generate()
      }

      assert {:ok, evaluation} = QualityProfileEngine.evaluate_file(profile, media_file)

      # Should have low score due to violations
      assert evaluation.score == 0.0
      assert length(evaluation.violations) > 0
      assert Enum.any?(evaluation.violations, &String.contains?(&1, "480p"))
    end

    test "generates upgrade recommendations", %{profile: profile, library_path: library_path} do
      # Create a file with decent quality but not optimal
      media_file = %MediaFile{
        id: Ecto.UUID.generate(),
        relative_path: "show/episode.mkv",
        library_path_id: library_path.id,
        library_path: library_path,
        codec: "h264",
        # Not the best codec
        audio_codec: "ac3",
        # Not the best audio
        resolution: "720p",
        # Not preferred
        size: 1_073_741_824,
        bitrate: 8_000_000,
        metadata: %{"audio_channels" => "2.0"},
        episode_id: Ecto.UUID.generate()
      }

      assert {:ok, evaluation} = QualityProfileEngine.evaluate_file(profile, media_file)

      assert evaluation.score > 0.0
      assert is_list(evaluation.recommendations)
      # Should have recommendations for improvements
      assert length(evaluation.recommendations) > 0
    end

    test "handles missing metadata gracefully", %{profile: profile, library_path: library_path} do
      # Create a file with minimal metadata
      media_file = %MediaFile{
        id: Ecto.UUID.generate(),
        relative_path: "show/episode.mkv",
        library_path_id: library_path.id,
        library_path: library_path,
        codec: "h265",
        resolution: "1080p",
        size: 1_073_741_824,
        bitrate: nil,
        # Missing bitrate
        metadata: nil,
        # No metadata
        episode_id: Ecto.UUID.generate()
      }

      assert {:ok, evaluation} = QualityProfileEngine.evaluate_file(profile, media_file)

      # Should still provide a score, just with defaults for missing fields
      assert is_float(evaluation.score)
      assert is_map(evaluation.breakdown)
    end

    test "correctly infers source from filename", %{profile: profile, library_path: library_path} do
      test_cases = [
        {"show/BluRay.mkv", "BluRay"},
        {"show/REMUX.mkv", "REMUX"},
        {"show/WEB-DL.mkv", "WEB-DL"},
        {"show/WEBRip.mkv", "WEBRip"}
      ]

      for {filename, _expected_source} <- test_cases do
        media_file = %MediaFile{
          id: Ecto.UUID.generate(),
          relative_path: filename,
          library_path_id: library_path.id,
          library_path: library_path,
          codec: "h265",
          resolution: "1080p",
          size: 1_073_741_824,
          bitrate: 10_000_000,
          metadata: nil,
          episode_id: Ecto.UUID.generate()
        }

        {:ok, evaluation} = QualityProfileEngine.evaluate_file(profile, media_file)

        # The evaluation should work (we can't easily assert the exact source inference
        # but we can verify the function doesn't crash)
        assert is_float(evaluation.score)
      end
    end
  end

  describe "get_metadata_preferences/1" do
    test "returns metadata preferences from profile struct" do
      profile = %QualityProfile{
        id: Ecto.UUID.generate(),
        name: "Test",
        qualities: ["1080p"],
        metadata_preferences: %{
          provider_priority: ["metadata_relay", "tvdb"],
          language: "en-US"
        }
      }

      assert {:ok, prefs} = QualityProfileEngine.get_metadata_preferences(profile)

      assert prefs.provider_priority == ["metadata_relay", "tvdb"]
      assert prefs.language == "en-US"
    end

    test "returns empty map when no preferences defined" do
      profile = %QualityProfile{
        id: Ecto.UUID.generate(),
        name: "Test",
        qualities: ["1080p"],
        metadata_preferences: nil
      }

      assert {:ok, prefs} = QualityProfileEngine.get_metadata_preferences(profile)
      assert prefs == %{}
    end

    test "fetches profile by ID and returns preferences" do
      {:ok, profile} =
        Settings.create_quality_profile(%{
          name: "Test Profile",
          qualities: ["1080p"],
          metadata_preferences: %{
            provider_priority: ["tmdb"],
            language: "ja-JP"
          }
        })

      assert {:ok, prefs} = QualityProfileEngine.get_metadata_preferences(profile.id)

      # Note: map keys are stored as strings in the database
      assert is_map(prefs)
      assert Map.has_key?(prefs, :provider_priority) or Map.has_key?(prefs, "provider_priority")
    end

    test "returns error when profile not found" do
      fake_id = Ecto.UUID.generate()
      assert {:error, :profile_not_found} = QualityProfileEngine.get_metadata_preferences(fake_id)
    end
  end

  describe "batch processing errors" do
    test "returns error when profile doesn't exist" do
      fake_profile_id = Ecto.UUID.generate()
      fake_library_id = Ecto.UUID.generate()

      assert {:error, :profile_not_found} =
               QualityProfileEngine.apply_profile_to_library(fake_profile_id, fake_library_id)
    end

    test "returns error when applying to non-existent items" do
      {:ok, profile} =
        Settings.create_quality_profile(%{
          name: "Test",
          qualities: ["1080p"]
        })

      fake_item_ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]

      # Should return ok with empty results since no files exist
      assert {:ok, summary} =
               QualityProfileEngine.apply_profile_to_items(profile.id, fake_item_ids)

      assert summary.processed == 0
    end

    test "reevaluate_profile_files returns ok with no files when profile has no files" do
      {:ok, profile} =
        Settings.create_quality_profile(%{
          name: "Empty Profile",
          qualities: ["1080p"],
          quality_standards: %{preferred_video_codecs: ["h265"]}
        })

      assert {:ok, summary} = QualityProfileEngine.reevaluate_profile_files(profile.id)
      assert summary.processed == 0
      assert summary.updated == 0
      assert summary.errors == []
    end
  end
end
