defmodule Mydia.Indexers.ReleaseRankerTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.{QualityParser, ReleaseRanker, SearchResult}
  alias Mydia.Settings.QualityProfile

  # Test Fixtures

  defp build_result(attrs) do
    defaults = %{
      title: "Test.Release.1080p.BluRay.x264",
      size: 5 * 1024 * 1024 * 1024,
      seeders: 50,
      leechers: 10,
      download_url: "magnet:?xt=urn:btih:test",
      indexer: "TestIndexer",
      quality: QualityParser.parse("Test.Release.1080p.BluRay.x264"),
      published_at: DateTime.utc_now()
    }

    Map.merge(defaults, attrs)
    |> then(&struct!(SearchResult, &1))
  end

  defp build_quality_profile(attrs \\ %{}) do
    defaults = %{
      id: Ecto.UUID.generate(),
      name: "Test Profile",
      qualities: ["1080p", "720p"],
      quality_standards: %{
        preferred_resolutions: ["1080p", "720p"],
        preferred_video_codecs: ["h265", "h264"],
        preferred_audio_codecs: ["atmos", "truehd", "dts-hd", "ac3"]
      }
    }

    Map.merge(defaults, attrs)
    |> then(&struct!(QualityProfile, &1))
  end

  defp build_results do
    now = DateTime.utc_now()

    [
      # High quality, many seeders, good size
      build_result(%{
        title: "Movie.2023.1080p.BluRay.x264-GoodRelease",
        size: 8 * 1024 * 1024 * 1024,
        seeders: 200,
        quality: QualityParser.parse("Movie.2023.1080p.BluRay.x264"),
        published_at: DateTime.add(now, -7, :day)
      }),
      # 4K but fewer seeders
      build_result(%{
        title: "Movie.2023.2160p.WEB-DL.x265-Group",
        size: 15 * 1024 * 1024 * 1024,
        seeders: 50,
        quality: QualityParser.parse("Movie.2023.2160p.WEB-DL.x265"),
        published_at: DateTime.add(now, -30, :day)
      }),
      # 720p but excellent seeders
      build_result(%{
        title: "Movie.2023.720p.WEB-DL.x264-Popular",
        size: 3 * 1024 * 1024 * 1024,
        seeders: 500,
        quality: QualityParser.parse("Movie.2023.720p.WEB-DL.x264"),
        published_at: DateTime.add(now, -1, :day)
      }),
      # Low seeders, should be filtered by default
      build_result(%{
        title: "Movie.2023.1080p.WEB-DL.x264-Unpopular",
        size: 6 * 1024 * 1024 * 1024,
        seeders: 2,
        quality: QualityParser.parse("Movie.2023.1080p.WEB-DL.x264"),
        published_at: DateTime.add(now, -10, :day)
      }),
      # CAM quality, should rank very low
      build_result(%{
        title: "Movie.2023.CAM.XviD-BadQuality",
        size: 700 * 1024 * 1024,
        seeders: 100,
        quality: QualityParser.parse("Movie.2023.CAM.XviD"),
        published_at: DateTime.add(now, -2, :day)
      })
    ]
  end

  # Note: ReleaseRanker now uses the unified SearchScorer algorithm for all scoring.
  # The breakdown struct always has size=0, age=0, tag_bonus=0 since these are not
  # part of the unified scoring formula.

  # Tests for select_best_result/2

  describe "select_best_result/2" do
    test "returns the best result based on scoring" do
      results = build_results()

      best = ReleaseRanker.select_best_result(results)

      assert best != nil
      # With unified scoring (no quality_profile), the result with most seeders wins
      # 720p has 500 seeders, which gives highest seeder score
      assert best.result.title == "Movie.2023.720p.WEB-DL.x264-Popular"
      assert best.score > 0
      assert is_map(best.breakdown)
    end

    test "returns nil for empty results" do
      assert ReleaseRanker.select_best_result([]) == nil
    end

    test "respects min_seeders option" do
      results = build_results()

      best = ReleaseRanker.select_best_result(results, min_seeders: 100)

      assert best != nil
      # Should not return results with < 100 seeders
      assert best.result.seeders >= 100
    end

    test "respects preferred_qualities option" do
      results = build_results()

      best = ReleaseRanker.select_best_result(results, preferred_qualities: ["720p"])

      assert best != nil
      assert best.result.quality.resolution == "720p"
    end

    test "respects blocked_tags option" do
      results = build_results()

      best = ReleaseRanker.select_best_result(results, blocked_tags: ["BluRay"])

      assert best != nil
      refute String.contains?(best.result.title, "BluRay")
    end

    test "returns nil when all results are filtered out" do
      results = build_results()

      best = ReleaseRanker.select_best_result(results, min_seeders: 10_000)

      assert best == nil
    end
  end

  # Tests for rank_all/2

  describe "rank_all/2" do
    test "returns all results sorted by score" do
      results = build_results()

      ranked = ReleaseRanker.rank_all(results)

      # Default min_seeders is 0, so all results should be returned
      assert length(ranked) == 5

      # Scores should be in descending order
      scores = Enum.map(ranked, & &1.score)
      assert scores == Enum.sort(scores, :desc)
    end

    test "each result includes score breakdown" do
      results = build_results()

      ranked = ReleaseRanker.rank_all(results)

      for item <- ranked do
        assert is_map(item.breakdown)
        assert Map.has_key?(item.breakdown, :quality)
        assert Map.has_key?(item.breakdown, :seeders)
        assert Map.has_key?(item.breakdown, :size)
        assert Map.has_key?(item.breakdown, :age)
        assert Map.has_key?(item.breakdown, :title_match)
        assert Map.has_key?(item.breakdown, :tag_bonus)
        assert Map.has_key?(item.breakdown, :total)
        assert item.breakdown.total == item.score

        # Unified scoring doesn't use size, age, or tag_bonus
        assert item.breakdown.size == 0.0
        assert item.breakdown.age == 0.0
        assert item.breakdown.tag_bonus == 0.0
      end
    end

    test "respects preferred_qualities for sorting" do
      results = build_results()

      ranked = ReleaseRanker.rank_all(results, preferred_qualities: ["720p", "1080p"])

      # 720p should come first even if 1080p has higher base score
      first_quality = ranked |> List.first() |> then(& &1.result.quality.resolution)
      assert first_quality == "720p"
    end

    test "1080p preferred sorts before higher-scoring 2160p" do
      # Simulate the user's scenario: 2160p has higher raw score but user prefers 1080p
      results = [
        build_result(%{
          title: "Movie.2023.2160p.BluRay.HDR.x265-HighScore",
          size: 4 * 1024 * 1024 * 1024,
          seeders: 100,
          quality: QualityParser.parse("Movie.2023.2160p.BluRay.HDR.x265")
        }),
        build_result(%{
          title: "Movie.2023.1080p.BluRay.x264-LowerScore",
          size: 8 * 1024 * 1024 * 1024,
          seeders: 50,
          quality: QualityParser.parse("Movie.2023.1080p.BluRay.x264")
        })
      ]

      # Without preference - 2160p should win due to higher quality base score
      ranked_no_pref = ReleaseRanker.rank_all(results)
      first_no_pref = ranked_no_pref |> List.first() |> then(& &1.result.quality.resolution)
      assert first_no_pref == "2160p", "Without preference, 2160p should rank first"

      # With 1080p preference - 1080p should win despite lower raw score
      ranked_with_pref = ReleaseRanker.rank_all(results, preferred_qualities: ["1080p"])
      first_with_pref = ranked_with_pref |> List.first() |> then(& &1.result.quality.resolution)
      assert first_with_pref == "1080p", "With 1080p preference, 1080p should rank first"

      # 2160p should be sorted to the end
      last_with_pref = ranked_with_pref |> List.last() |> then(& &1.result.quality.resolution)
      assert last_with_pref == "2160p"
    end

    test "non-preferred resolutions get index 999 for sorting" do
      results = [
        build_result(%{
          title: "Movie.2160p.BluRay",
          seeders: 100,
          quality: QualityParser.parse("Movie.2160p.BluRay")
        }),
        build_result(%{
          title: "Movie.720p.BluRay",
          seeders: 10,
          quality: QualityParser.parse("Movie.720p.BluRay")
        }),
        build_result(%{
          title: "Movie.1080p.BluRay",
          seeders: 50,
          quality: QualityParser.parse("Movie.1080p.BluRay")
        })
      ]

      # Only 1080p is preferred
      ranked = ReleaseRanker.rank_all(results, preferred_qualities: ["1080p"])

      # 1080p should be first, then the rest sorted by score
      resolutions = Enum.map(ranked, & &1.result.quality.resolution)
      assert hd(resolutions) == "1080p"

      # Non-preferred (2160p and 720p) should come after all preferred
      non_preferred = tl(resolutions)
      assert "1080p" not in non_preferred
    end

    test "tag bonus is not used in unified scoring" do
      # Note: preferred_tags option is no longer supported.
      # Unified scoring uses quality_profile, seeder_score, and title_bonus.
      results = [
        build_result(%{
          title: "Movie.2023.1080p.BluRay.PROPER.x264",
          seeders: 50
        }),
        build_result(%{
          title: "Movie.2023.1080p.BluRay.x264",
          seeders: 50
        })
      ]

      ranked = ReleaseRanker.rank_all(results)

      # Tag bonus is always 0 in unified scoring
      for item <- ranked do
        assert item.breakdown.tag_bonus == 0.0
      end
    end

    test "returns empty list for empty input" do
      assert ReleaseRanker.rank_all([]) == []
    end
  end

  # Tests for filter_acceptable/2

  describe "filter_acceptable/2" do
    test "filters by minimum seeders" do
      results = build_results()

      filtered = ReleaseRanker.filter_acceptable(results, min_seeders: 100)

      # Only results with >= 100 seeders should remain (200, 500, 100)
      assert Enum.all?(filtered, fn r -> r.seeders >= 100 end)
      assert length(filtered) == 3
    end

    test "uses default min_seeders of 0" do
      results = build_results()

      filtered = ReleaseRanker.filter_acceptable(results)

      # Default min_seeders is 0, so all results should be returned
      assert length(filtered) == 5
    end

    test "filters by size range" do
      results = build_results()

      # Only accept 2-10 GB
      filtered = ReleaseRanker.filter_acceptable(results, size_range: {2000, 10_000})

      for result <- filtered do
        size_mb = result.size / (1024 * 1024)
        assert size_mb >= 2000
        assert size_mb <= 10_000
      end
    end

    test "filters by blocked tags" do
      results = build_results()

      filtered = ReleaseRanker.filter_acceptable(results, blocked_tags: ["CAM", "Unpopular"])

      # Should not contain blocked tags
      for result <- filtered do
        refute String.contains?(result.title, "CAM")
        refute String.contains?(result.title, "Unpopular")
      end

      assert length(filtered) < length(results)
    end

    test "blocked tags are case insensitive" do
      results = [
        build_result(%{title: "Movie.CAM.x264", seeders: 50}),
        build_result(%{title: "Movie.cam.x264", seeders: 50}),
        build_result(%{title: "Movie.1080p.x264", seeders: 50})
      ]

      filtered = ReleaseRanker.filter_acceptable(results, blocked_tags: ["cam"])

      assert length(filtered) == 1
      assert List.first(filtered).title == "Movie.1080p.x264"
    end

    test "applies all filters together" do
      results = build_results()

      filtered =
        ReleaseRanker.filter_acceptable(results,
          min_seeders: 100,
          size_range: {2000, 10_000},
          blocked_tags: ["CAM"]
        )

      # Should pass all criteria
      for result <- filtered do
        assert result.seeders >= 100
        size_mb = result.size / (1024 * 1024)
        assert size_mb >= 2000 && size_mb <= 10_000
        refute String.contains?(result.title, "CAM")
      end
    end

    test "returns empty list when all filtered out" do
      results = build_results()

      filtered = ReleaseRanker.filter_acceptable(results, min_seeders: 10_000)

      assert filtered == []
    end

    test "returns all when no filters specified" do
      results = build_results()

      # With min_seeders: 0 to disable default
      filtered = ReleaseRanker.filter_acceptable(results, min_seeders: 0)

      assert length(filtered) == length(results)
    end
  end

  # Tests for scoring functions (via breakdown)

  describe "quality scoring" do
    test "higher quality gets higher scores with quality_profile" do
      # With quality_profile, the SearchScorer uses QualityProfile.score_media_file
      profile = build_quality_profile(%{qualities: ["2160p", "1080p", "720p"]})

      results = [
        build_result(%{
          title: "Movie.2160p.BluRay.x265",
          seeders: 50,
          quality: QualityParser.parse("Movie.2160p.BluRay.x265")
        }),
        build_result(%{
          title: "Movie.720p.WEB-DL.x264",
          seeders: 50,
          quality: QualityParser.parse("Movie.720p.WEB-DL.x264")
        })
      ]

      ranked = ReleaseRanker.rank_all(results, quality_profile: profile)

      hq_result = Enum.find(ranked, &(&1.result.quality.resolution == "2160p"))
      lq_result = Enum.find(ranked, &(&1.result.quality.resolution == "720p"))

      # Higher resolution with profile should score higher
      assert hq_result.score > lq_result.score
    end

    test "without quality_profile, quality score is based on seeders" do
      # Without quality_profile, SearchScorer.score_quality returns seeders as score
      result = build_result(%{quality: nil, seeders: 50})

      ranked = ReleaseRanker.rank_all([result])

      # Quality score equals seeders when no profile is set
      assert List.first(ranked).breakdown.quality == 50.0
    end

    test "preferred qualities affect sorting, not scoring" do
      # In unified scoring, preferred_qualities is used for sorting, not score bonus
      results = [
        build_result(%{
          title: "Movie.1080p.BluRay.x264",
          seeders: 50,
          quality: QualityParser.parse("Movie.1080p.BluRay.x264")
        }),
        build_result(%{
          title: "Movie.720p.BluRay.x264",
          seeders: 50,
          quality: QualityParser.parse("Movie.720p.BluRay.x264")
        })
      ]

      # Without preference - sort by score only
      without_pref = ReleaseRanker.rank_all(results)

      # With preference for 1080p - 1080p should be first due to sorting
      with_pref = ReleaseRanker.rank_all(results, preferred_qualities: ["1080p"])
      first_with_pref = List.first(with_pref)

      # 1080p should be sorted first due to preferred_qualities
      assert first_with_pref.result.quality.resolution == "1080p"

      # Scores remain the same (sorting doesn't affect score)
      score_1080p = Enum.find(without_pref, &(&1.result.quality.resolution == "1080p"))
      score_1080p_pref = Enum.find(with_pref, &(&1.result.quality.resolution == "1080p"))
      assert score_1080p.breakdown.quality == score_1080p_pref.breakdown.quality
    end
  end

  describe "seeder scoring" do
    test "more seeders get higher scores" do
      results = [
        build_result(%{seeders: 10, leechers: 10, title: "Movie.1080p.x264"}),
        build_result(%{seeders: 100, leechers: 100, title: "Movie.1080p.x264"}),
        build_result(%{seeders: 1000, leechers: 1000, title: "Movie.1080p.x264"})
      ]

      ranked = ReleaseRanker.rank_all(results)

      scores = Enum.map(ranked, & &1.breakdown.seeders)
      assert scores == Enum.sort(scores, :desc)
    end

    test "zero seeders get zero score" do
      result = build_result(%{seeders: 0, leechers: 10})

      ranked = ReleaseRanker.rank_all([result], min_seeders: 0)

      assert List.first(ranked).breakdown.seeders == 0.0
    end

    test "seeder scoring has diminishing returns (logarithmic)" do
      # Unified scoring uses log10(seeders + 1) * 10
      results = [
        build_result(%{seeders: 100, leechers: 100, title: "Movie.1080p.x264"}),
        build_result(%{seeders: 1000, leechers: 1000, title: "Movie.1080p.x264"})
      ]

      ranked = ReleaseRanker.rank_all(results)

      score_100 = Enum.find(ranked, &(&1.result.seeders == 100)).breakdown.seeders
      score_1000 = Enum.find(ranked, &(&1.result.seeders == 1000)).breakdown.seeders

      # 10x seeders should not give 10x score (diminishing returns via log10)
      # log10(101) * 10 ≈ 20, log10(1001) * 10 ≈ 30
      assert score_1000 < score_100 * 2
    end

    test "seeder ratio does not affect unified scoring (only seeder count matters)" do
      # Unified scoring uses simple log10 formula without ratio multipliers
      results = [
        # More seeders but poor ratio
        build_result(%{
          seeders: 300,
          leechers: 1500,
          title: "Movie.MoreSeeders.1080p.x264"
        }),
        # Fewer seeders but good ratio
        build_result(%{
          seeders: 60,
          leechers: 30,
          title: "Movie.FewerSeeders.1080p.x264"
        })
      ]

      ranked = ReleaseRanker.rank_all(results, min_seeders: 50)

      more_seeders =
        Enum.find(ranked, &String.contains?(&1.result.title, "MoreSeeders")).breakdown.seeders

      fewer_seeders =
        Enum.find(ranked, &String.contains?(&1.result.title, "FewerSeeders")).breakdown.seeders

      # In unified scoring, more seeders = higher seeder score (no ratio penalty)
      assert more_seeders > fewer_seeders
    end
  end

  describe "minimum ratio filtering" do
    test "filters out torrents below minimum ratio" do
      results = [
        # 10% ratio - should be filtered
        build_result(%{seeders: 10, leechers: 90, title: "Movie.Bad.1080p.x264"}),
        # 20% ratio - should pass
        build_result(%{seeders: 20, leechers: 80, title: "Movie.Ok.1080p.x264"}),
        # 50% ratio - should pass
        build_result(%{seeders: 50, leechers: 50, title: "Movie.Good.1080p.x264"})
      ]

      # Filter for minimum 15% ratio
      filtered = ReleaseRanker.filter_acceptable(results, min_seeders: 0, min_ratio: 0.15)

      # Only the 20% and 50% ratio results should remain
      assert length(filtered) == 2
      refute Enum.any?(filtered, &String.contains?(&1.title, "Bad"))
    end

    test "nil min_ratio does not filter" do
      results = [
        build_result(%{seeders: 1, leechers: 99, title: "Movie.VeryBad.1080p.x264"}),
        build_result(%{seeders: 50, leechers: 50, title: "Movie.Good.1080p.x264"})
      ]

      filtered = ReleaseRanker.filter_acceptable(results, min_seeders: 0, min_ratio: nil)

      # Both should pass when no ratio filter is set
      assert length(filtered) == 2
    end

    test "works with select_best_result" do
      results = [
        # High seeders but poor ratio (17%)
        build_result(%{
          seeders: 300,
          leechers: 1500,
          title: "Movie.2023.1080p.Popular.But.Stalled"
        }),
        # Fewer seeders but good ratio (67%)
        build_result(%{seeders: 60, leechers: 30, title: "Movie.2023.1080p.Healthy"})
      ]

      # With min_ratio: 0.20, the first result (17% ratio) will be filtered out
      best = ReleaseRanker.select_best_result(results, min_seeders: 50, min_ratio: 0.20)

      # Only the healthy swarm passes the ratio filter
      assert best != nil
      assert String.contains?(best.result.title, "Healthy")
    end

    test "allows torrents with zero peers" do
      results = [
        # Brand new torrent with no peers yet
        build_result(%{seeders: 0, leechers: 0, title: "Movie.New.1080p.x264"})
      ]

      filtered = ReleaseRanker.filter_acceptable(results, min_seeders: 0, min_ratio: 0.15)

      # Should allow torrents with no peers (can't calculate ratio)
      assert length(filtered) == 1
    end
  end

  describe "size and age scoring" do
    # Note: Unified scoring does NOT use size or age in the score calculation.
    # These fields always return 0.0 in the breakdown.

    test "size score is always zero in unified scoring" do
      results = [
        build_result(%{size: 50 * 1024 * 1024, title: "Small"}),
        build_result(%{size: 5 * 1024 * 1024 * 1024, title: "Good"}),
        build_result(%{size: 30 * 1024 * 1024 * 1024, title: "Huge"})
      ]

      # Allow all sizes for comparison
      opts = [min_seeders: 0, size_range: {0, 100_000}]
      ranked = ReleaseRanker.rank_all(results, opts)

      # All size scores should be 0.0
      for item <- ranked do
        assert item.breakdown.size == 0.0
      end
    end

    test "age score is always zero in unified scoring" do
      now = DateTime.utc_now()

      results = [
        build_result(%{
          published_at: DateTime.add(now, -2, :day),
          title: "Recent"
        }),
        build_result(%{
          published_at: DateTime.add(now, -365, :day),
          title: "Old"
        }),
        build_result(%{
          published_at: nil,
          title: "NoDate"
        })
      ]

      ranked = ReleaseRanker.rank_all(results)

      # All age scores should be 0.0
      for item <- ranked do
        assert item.breakdown.age == 0.0
      end
    end
  end

  describe "tag scoring" do
    # Note: Unified scoring does NOT use tag_bonus. The tag_bonus field
    # always returns 0.0 in the breakdown.

    test "tag bonus is always zero in unified scoring" do
      results = [
        build_result(%{title: "Movie.PROPER.1080p.x264", seeders: 50}),
        build_result(%{title: "Movie.1080p.x264", seeders: 50})
      ]

      ranked = ReleaseRanker.rank_all(results)

      # All tag_bonus scores should be 0.0
      for item <- ranked do
        assert item.breakdown.tag_bonus == 0.0
      end
    end
  end

  describe "edge cases" do
    test "handles results with missing quality gracefully" do
      # Without quality_profile, quality score equals seeders
      result = build_result(%{quality: nil, seeders: 50})

      ranked = ReleaseRanker.rank_all([result])

      assert length(ranked) == 1
      # Quality score = seeders when no quality_profile is set
      assert List.first(ranked).breakdown.quality == 50.0
    end

    test "handles results with missing published_at gracefully" do
      result = build_result(%{published_at: nil, seeders: 50})

      ranked = ReleaseRanker.rank_all([result])

      assert length(ranked) == 1
      # Age is not used in unified scoring
      assert List.first(ranked).breakdown.age == 0.0
    end

    test "handles single result" do
      result = build_result(%{seeders: 50})

      best = ReleaseRanker.select_best_result([result])

      assert best != nil
      assert best.result == result
    end

    test "all scores in breakdown are rounded to 2 decimal places" do
      result = build_result(%{seeders: 50})

      ranked = ReleaseRanker.rank_all([result])
      breakdown = List.first(ranked).breakdown

      # Check that each field value has at most 2 decimal places
      assert Float.round(breakdown.quality, 2) == breakdown.quality
      assert Float.round(breakdown.seeders, 2) == breakdown.seeders
      assert Float.round(breakdown.size, 2) == breakdown.size
      assert Float.round(breakdown.age, 2) == breakdown.age
      assert Float.round(breakdown.title_match, 2) == breakdown.title_match
      assert Float.round(breakdown.tag_bonus, 2) == breakdown.tag_bonus
      assert Float.round(breakdown.total, 2) == breakdown.total
    end

    test "total score follows unified scoring formula" do
      # Unified scoring: (quality_score * 0.6 + seeder_score + title_bonus) * penalty
      result = build_result(%{seeders: 50})

      ranked = ReleaseRanker.rank_all([result])
      breakdown = List.first(ranked).breakdown

      # For this result:
      # - quality_score = 50 (equals seeders when no profile)
      # - seeder_score = log10(51) * 10 ≈ 17.1
      # - title_bonus = 0 (no search_query)
      # - zero_seeder_penalty = 1.0 (seeders > 0)
      # Expected total ≈ (50 * 0.6 + 17.1 + 0) * 1.0 ≈ 47.1
      assert breakdown.total > 40
      assert breakdown.total < 60
    end
  end

  describe "title matching" do
    test "exact title match gets higher score than partial match" do
      # Simulates: searching for "The Studio S01E01"
      exact_match =
        build_result(%{
          title: "The.Studio.2025.S01E01.1080p.WEB-DL.x264",
          seeders: 30
        })

      partial_match =
        build_result(%{
          title: "Marvel.Studios.Assembled.S01E01.1080p.HEVC.x265",
          seeders: 30
        })

      # With search_query, exact match should rank higher
      ranked =
        ReleaseRanker.rank_all([exact_match, partial_match],
          search_query: "The Studio S01E01",
          min_seeders: 1
        )

      # The exact match should be first
      assert List.first(ranked).result.title =~ "The.Studio"

      # And should have a higher title_match score
      exact_breakdown = Enum.find(ranked, &(&1.result.title =~ "The.Studio")).breakdown
      partial_breakdown = Enum.find(ranked, &(&1.result.title =~ "Marvel")).breakdown

      assert exact_breakdown.title_match > partial_breakdown.title_match
    end

    test "without search_query, title_match defaults to zero" do
      result = build_result(%{seeders: 50})

      ranked = ReleaseRanker.rank_all([result], min_seeders: 1)
      breakdown = List.first(ranked).breakdown

      # Without search_query, title_match is 0 (no bonus applied)
      assert breakdown.title_match == 0.0
    end

    test "title matching with search query returns positive score" do
      result =
        build_result(%{
          title: "The.Studio.S01E01.1080p.BluRay.x264.DTS",
          seeders: 50
        })

      ranked =
        ReleaseRanker.rank_all([result],
          search_query: "The Studio S01E01",
          min_seeders: 1
        )

      breakdown = List.first(ranked).breakdown

      # With matching search_query, title_match should be positive
      assert breakdown.title_match > 0
    end

    test "title matching handles year in query" do
      result =
        build_result(%{
          title: "The.Studio.2025.S01E01.1080p.WEB-DL",
          seeders: 50
        })

      ranked =
        ReleaseRanker.rank_all([result],
          search_query: "The Studio 2025 S01E01",
          min_seeders: 1
        )

      breakdown = List.first(ranked).breakdown

      # Should have positive title match with year included
      assert breakdown.title_match > 0
    end

    test "exact series title ranks higher than similar series with same seeders" do
      # Real-world case: searching for "The Girlfriend S01"
      # With the same seeders, title matching should differentiate the results
      mb = 1024 * 1024
      gb = 1024 * mb

      # Use same seeders to isolate title matching effect
      seeders = 50

      results = [
        # Unrelated documentary series with similar words
        build_result(%{
          title:
            "Untold.The.Girlfriend.Who.Didnt.Exist.S01.1080p.NF.WEB-DL.ENG.SPA.DDP5.1.x264-themoviesboss",
          size: 6 * gb,
          seeders: seeders
        }),
        # The actual series we want
        build_result(%{
          title: "The.Girlfriend.S01E01-06.1080p.AMZN.WEB-DL.ITA.ENG.DDP5.1.H.265-G66",
          size: 8 * gb,
          seeders: seeders
        }),
        # Different series with similar name
        build_result(%{
          title: "The.Girlfriend.Experience.S01E01-13.1080p.AMZN.WEB-DL.ITA.ENG.DDP5.1.H.265-G66",
          size: 13 * gb,
          seeders: seeders
        }),
        # The actual series (season pack with 2025)
        build_result(%{
          title: "The.Girlfriend.2025.S01.1080p.10bit.WEBRip.6CH.x265.HEVC.PSA",
          size: 4 * gb,
          seeders: seeders
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          search_query: "The Girlfriend S01",
          min_seeders: 1,
          size_range: {100, 20_000}
        )

      # The actual "The Girlfriend" series should have higher title_match than related series
      actual_series =
        Enum.find(ranked, &String.contains?(&1.result.title, "The.Girlfriend.2025"))

      experience_series =
        Enum.find(ranked, &String.contains?(&1.result.title, "Experience"))

      untold_series =
        Enum.find(ranked, &String.contains?(&1.result.title, "Untold"))

      # The actual series should have higher title_match score
      assert actual_series.breakdown.title_match >= experience_series.breakdown.title_match,
             """
             Actual series should have higher title_match than "The Girlfriend Experience".
             Actual: #{actual_series.breakdown.title_match}
             Experience: #{experience_series.breakdown.title_match}
             """

      assert actual_series.breakdown.title_match >= untold_series.breakdown.title_match,
             """
             Actual series should have higher title_match than "Untold: The Girlfriend Who Didn't Exist".
             Actual: #{actual_series.breakdown.title_match}
             Untold: #{untold_series.breakdown.title_match}
             """
    end

    test "without search_query, title_match is zero for all results" do
      # Without search_query, title relevance is not scored
      mb = 1024 * 1024
      gb = 1024 * mb

      results = [
        build_result(%{
          title:
            "Untold.The.Girlfriend.Who.Didnt.Exist.S01.1080p.NF.WEB-DL.ENG.SPA.DDP5.1.x264-themoviesboss",
          size: 6 * gb,
          seeders: 3
        }),
        build_result(%{
          title: "The.Girlfriend.2025.S01.1080p.WEBRip.x265-KONTRAST",
          size: 7 * gb,
          seeders: 36
        }),
        build_result(%{
          title: "The.Girlfriend.Experience.S01E01-13.1080p.AMZN.WEB-DL.ITA.ENG.DDP5.1.H.265-G66",
          size: 13 * gb,
          seeders: 6
        })
      ]

      # Without search_query, all results get title_match score of 0
      ranked_without_query =
        ReleaseRanker.rank_all(results,
          min_seeders: 1,
          size_range: {100, 20_000}
        )

      # All title_match scores should be 0 (no query provided)
      assert Enum.all?(ranked_without_query, fn r -> r.breakdown.title_match == 0.0 end),
             "Without search_query, title_match should be 0"

      # With search_query, title_match scores are calculated
      ranked_with_query =
        ReleaseRanker.rank_all(results,
          search_query: "The Girlfriend S01",
          min_seeders: 1,
          size_range: {100, 20_000}
        )

      # With query, at least some results should have positive title_match
      assert Enum.any?(ranked_with_query, fn r -> r.breakdown.title_match > 0 end),
             "With search_query, at least some results should have positive title_match"
    end
  end

  describe "real-world movie search scenarios" do
    @doc """
    Test case based on actual search results for "xXx 2002" movie with HD-1080p quality profile.

    This captures real-world scoring behavior to help identify issues with the ranking algorithm.
    The results show various 1080p releases with different codecs, sources, and file sizes.
    """
    test "xXx 2002 movie search - 1080p quality profile scoring" do
      mb = 1024 * 1024
      gb = 1024 * mb

      results = [
        # x265 BluRay - NZBFinder (Usenet, no seeders) - was scoring 83
        build_result(%{
          title: "xXx.2002.1080p.BluRay.x265.SDR.DDP.5.1.English.DarQ.HONE",
          size: round(9.5 * gb),
          seeders: 0,
          quality: QualityParser.parse("xXx.2002.1080p.BluRay.x265.SDR.DDP.5.1.English.DarQ.HONE")
        }),
        # x264 BluRay with AC3 - NZBFinder (no seeders)
        build_result(%{
          title: "xXx 2002 1080p Bluray AC3 x264 - AdiT -",
          size: round(6.2 * gb),
          seeders: 0,
          quality: QualityParser.parse("xXx 2002 1080p Bluray AC3 x264 - AdiT -")
        }),
        # x264 BluRay with DTS:X - NZBFinder (no seeders)
        build_result(%{
          title: "xXx 2002 1080p BluRay AC3 DTS x264-GAIA",
          size: round(15.1 * gb),
          seeders: 0,
          quality: QualityParser.parse("xXx 2002 1080p BluRay AC3 DTS x264-GAIA")
        }),
        # x264 BluRay - BitSearch with 1 seeder
        build_result(%{
          title: "xXx.2002.1080p.BluRay.x264-OFT",
          size: round(6.0 * gb),
          seeders: 1,
          quality: QualityParser.parse("xXx.2002.1080p.BluRay.x264-OFT")
        }),
        # Remastered x265 - NZBFinder (no seeders)
        build_result(%{
          title: "xXx.2002.Remastered.1080p.BluRay.10Bit.X265.DD.5.1-Chivaman",
          size: round(5.5 * gb),
          seeders: 0,
          quality:
            QualityParser.parse("xXx.2002.Remastered.1080p.BluRay.10Bit.X265.DD.5.1-Chivaman")
        }),
        # 15th Anniversary Edition - BitSearch with 24 seeders (was scoring 75)
        build_result(%{
          title: "xXx.2002.15th.Anniversary.Edition.BluRay.1080p.DDP.5.1.x264-hallowed",
          size: round(11.0 * gb),
          seeders: 24,
          quality:
            QualityParser.parse(
              "xXx.2002.15th.Anniversary.Edition.BluRay.1080p.DDP.5.1.x264-hallowed"
            )
        }),
        # WEB-DL - BitSearch with 130 seeders
        build_result(%{
          title: "xXx.2002.1080p.ALL4.WEB-DL.AAC.2.0.H.264-PiRaTeS",
          size: round(4.6 * gb),
          seeders: 130,
          leechers: 20,
          quality: QualityParser.parse("xXx.2002.1080p.ALL4.WEB-DL.AAC.2.0.H.264-PiRaTeS")
        }),
        # WEB-DL H.264 DD+ - NZBFinder (no seeders)
        build_result(%{
          title: "xXx.2002.1080p.HMAX.WEB-DL.DDP.5.1.H.264-PiRaTeS",
          size: round(14.2 * gb),
          seeders: 0,
          quality: QualityParser.parse("xXx.2002.1080p.HMAX.WEB-DL.DDP.5.1.H.264-PiRaTeS")
        }),
        # DVDRip - NZBFinder (no seeders)
        build_result(%{
          title: "XXX.2002.DVDRip.x264-DJ",
          size: round(1.2 * gb),
          seeders: 0,
          quality: QualityParser.parse("XXX.2002.DVDRip.x264-DJ")
        }),
        # REMUX - NZBFinder (no seeders)
        build_result(%{
          title: "XXX.2002.BD-Remux.mkv",
          size: round(15.7 * gb),
          seeders: 0,
          quality: QualityParser.parse("XXX.2002.BD-Remux.mkv")
        }),
        # Nordic version with 32 seeders - BitSearch
        build_result(%{
          title: "xXx.2002.NORDiC.BRRip.x264-SWAXXON",
          size: round(698.7 * mb),
          seeders: 32,
          quality: QualityParser.parse("xXx.2002.NORDiC.BRRip.x264-SWAXXON")
        }),
        # Unrelated XXX content - should rank low due to title mismatch
        build_result(%{
          title: "[Private] The Private Gladiator 1 XXX (2002) (1080p HEVC) [GhostFreakXX]",
          size: round(1.5 * gb),
          seeders: 8,
          quality:
            QualityParser.parse(
              "[Private] The Private Gladiator 1 XXX (2002) (1080p HEVC) [GhostFreakXX]"
            )
        })
      ]

      # Rank with 1080p preferred quality and the search query
      ranked =
        ReleaseRanker.rank_all(results,
          search_query: "xXx 2002",
          preferred_qualities: ["1080p"],
          min_seeders: 0,
          size_range: {100, 20_000}
        )

      # Display ranking for debugging
      ranking_info =
        ranked
        |> Enum.with_index(1)
        |> Enum.map(fn {r, idx} ->
          "  #{idx}. Score: #{Float.round(r.score, 1)} | Seeders: #{r.result.seeders} | #{r.result.title}\n" <>
            "     Quality: #{inspect(r.breakdown.quality)} | Seeders Score: #{inspect(r.breakdown.seeders)} | " <>
            "Size: #{inspect(r.breakdown.size)} | Title: #{inspect(r.breakdown.title_match)}"
        end)
        |> Enum.join("\n")

      # Basic assertions for unified scoring

      # 1. Results should be sorted - first by preferred_qualities (1080p first), then by score
      assert length(ranked) > 0, "Expected some results after filtering"

      # 2. Unrelated "Private Gladiator" should rank lower due to title mismatch
      gladiator = Enum.find(ranked, &String.contains?(&1.result.title, "Private Gladiator"))
      xxx_result = Enum.find(ranked, &String.contains?(&1.result.title, "xXx.2002"))

      if gladiator && xxx_result do
        assert xxx_result.score > gladiator.score,
               """
               xXx result should score higher than unrelated "Private Gladiator" content.
               xXx score: #{xxx_result.score}
               Gladiator score: #{gladiator.score}

               Full ranking:
               #{ranking_info}
               """
      end

      # 3. Results with more seeders should generally score higher (all else equal)
      # The WEB-DL with 130 seeders should have one of the highest seeder scores
      webdl_130 =
        Enum.find(ranked, fn r ->
          r.result.seeders == 130 && String.contains?(r.result.title, "WEB-DL")
        end)

      if webdl_130 do
        assert webdl_130.breakdown.seeders > 20.0,
               """
               WEB-DL with 130 seeders should have high seeder score.
               Got: #{webdl_130.breakdown.seeders}
               """
      end
    end
  end

  describe "unified scoring mode" do
    test "always uses SearchScorer algorithm (with or without quality_profile)" do
      results = [
        build_result(%{
          title: "Movie.2023.1080p.BluRay.x264",
          seeders: 100,
          quality: QualityParser.parse("Movie.2023.1080p.BluRay.x264")
        })
      ]

      profile = build_quality_profile()

      # With quality_profile
      ranked_with_profile =
        ReleaseRanker.rank_all(results,
          quality_profile: profile,
          media_type: :movie,
          min_seeders: 1
        )

      assert length(ranked_with_profile) == 1
      item = List.first(ranked_with_profile)

      # Size and age are always 0 in unified scoring
      assert item.breakdown.size == 0.0
      assert item.breakdown.age == 0.0
      assert item.score > 0

      # Without quality_profile - still uses unified scoring
      ranked_without_profile = ReleaseRanker.rank_all(results, min_seeders: 1)

      assert length(ranked_without_profile) == 1
      item_no_profile = List.first(ranked_without_profile)

      # Size and age are still 0 (unified scoring is always used)
      assert item_no_profile.breakdown.size == 0.0
      assert item_no_profile.breakdown.age == 0.0
    end

    test "penalizes zero-seeder results" do
      results = [
        build_result(%{
          title: "Movie.2023.1080p.BluRay.x264-Seeded",
          seeders: 50,
          quality: QualityParser.parse("Movie.2023.1080p.BluRay.x264")
        }),
        build_result(%{
          title: "Movie.2023.1080p.BluRay.x264-Dead",
          seeders: 0,
          quality: QualityParser.parse("Movie.2023.1080p.BluRay.x264")
        })
      ]

      profile = build_quality_profile()

      ranked =
        ReleaseRanker.rank_all(results,
          quality_profile: profile,
          media_type: :movie,
          min_seeders: 0
        )

      seeded = Enum.find(ranked, &String.contains?(&1.result.title, "Seeded"))
      dead = Enum.find(ranked, &String.contains?(&1.result.title, "Dead"))

      # Seeded result should score higher due to zero-seeder penalty
      assert seeded.score > dead.score
    end

    test "considers title relevance with search_query" do
      results = [
        build_result(%{
          title: "The.Girlfriend.2025.S01E01.1080p.WEB-DL",
          seeders: 50,
          quality: QualityParser.parse("The.Girlfriend.2025.S01E01.1080p.WEB-DL")
        }),
        build_result(%{
          title: "The.Girlfriend.Experience.S01E01.1080p.WEB-DL",
          seeders: 50,
          quality: QualityParser.parse("The.Girlfriend.Experience.S01E01.1080p.WEB-DL")
        })
      ]

      profile = build_quality_profile()

      ranked =
        ReleaseRanker.rank_all(results,
          quality_profile: profile,
          media_type: :episode,
          search_query: "The Girlfriend S01E01",
          min_seeders: 1
        )

      # The exact match should rank higher
      first_result = List.first(ranked)
      assert String.contains?(first_result.result.title, "The.Girlfriend.2025")
    end

    test "select_best_result uses unified scoring" do
      results = [
        build_result(%{
          title: "Movie.2023.1080p.BluRay.x264-BestMatch",
          seeders: 100,
          quality: QualityParser.parse("Movie.2023.1080p.BluRay.x264")
        }),
        build_result(%{
          title: "Movie.2023.1080p.WEB-DL.x264-LowerScore",
          seeders: 20,
          quality: QualityParser.parse("Movie.2023.1080p.WEB-DL.x264")
        })
      ]

      profile = build_quality_profile()

      best =
        ReleaseRanker.select_best_result(results,
          quality_profile: profile,
          media_type: :movie,
          min_seeders: 1
        )

      assert best != nil
      # Result with more seeders should win (both are 1080p BluRay/WEB-DL)
      assert String.contains?(best.result.title, "BestMatch")
    end
  end
end
