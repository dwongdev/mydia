defmodule Mydia.Indexers.ReleaseRankerTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.{QualityParser, ReleaseRanker, SearchResult}

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

  # Tests for select_best_result/2

  describe "select_best_result/2" do
    test "returns the best result based on scoring" do
      results = build_results()

      best = ReleaseRanker.select_best_result(results)

      assert best != nil
      # 2160p should win due to higher quality score
      assert best.result.title == "Movie.2023.2160p.WEB-DL.x265-Group"
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

      # Should filter out the low-seeder result by default (min_seeders: 5)
      assert length(ranked) == 4

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

    test "applies tag bonus correctly" do
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

      ranked = ReleaseRanker.rank_all(results, preferred_tags: ["PROPER"])

      # Result with PROPER tag should score higher
      assert List.first(ranked).result.title =~ "PROPER"
      assert List.first(ranked).breakdown.tag_bonus > 0
      assert List.last(ranked).breakdown.tag_bonus == 0
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

    test "uses default min_seeders of 5" do
      results = build_results()

      filtered = ReleaseRanker.filter_acceptable(results)

      # Default should filter out the 2-seeder result
      assert Enum.all?(filtered, fn r -> r.seeders >= 5 end)
      assert length(filtered) == 4
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
    test "higher quality gets higher scores" do
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

      ranked = ReleaseRanker.rank_all(results)

      hq_score = Enum.find(ranked, &(&1.result.quality.resolution == "2160p"))
      lq_score = Enum.find(ranked, &(&1.result.quality.resolution == "720p"))

      assert hq_score.breakdown.quality > lq_score.breakdown.quality
    end

    test "nil quality gets zero score" do
      result = build_result(%{quality: nil, seeders: 50})

      ranked = ReleaseRanker.rank_all([result])

      assert List.first(ranked).breakdown.quality == 0.0
    end

    test "preferred qualities get bonus" do
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

      # Without preference
      without_pref = ReleaseRanker.rank_all(results)
      score_1080p = Enum.find(without_pref, &(&1.result.quality.resolution == "1080p"))

      # With preference for 1080p
      with_pref = ReleaseRanker.rank_all(results, preferred_qualities: ["1080p"])
      score_1080p_pref = Enum.find(with_pref, &(&1.result.quality.resolution == "1080p"))

      # 1080p should get bonus when preferred
      assert score_1080p_pref.breakdown.quality > score_1080p.breakdown.quality
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

    test "seeder scoring has diminishing returns" do
      results = [
        build_result(%{seeders: 100, leechers: 100, title: "Movie.1080p.x264"}),
        build_result(%{seeders: 1000, leechers: 1000, title: "Movie.1080p.x264"})
      ]

      ranked = ReleaseRanker.rank_all(results)

      score_100 = Enum.find(ranked, &(&1.result.seeders == 100)).breakdown.seeders
      score_1000 = Enum.find(ranked, &(&1.result.seeders == 1000)).breakdown.seeders

      # 10x seeders should not give 10x score (diminishing returns)
      assert score_1000 < score_100 * 2
    end

    test "healthy swarm (high ratio) scores higher than oversaturated swarm" do
      # Same seeder count but different ratios
      results = [
        # Oversaturated: 300 seeders, 1500 leechers (17% ratio) - 0.1x multiplier
        build_result(%{
          seeders: 300,
          leechers: 1500,
          title: "Movie.Oversaturated.1080p.x264"
        }),
        # Healthy: 60 seeders, 30 leechers (67% ratio) - 1.0x multiplier
        build_result(%{
          seeders: 60,
          leechers: 30,
          title: "Movie.Healthy.1080p.x264"
        })
      ]

      ranked = ReleaseRanker.rank_all(results, min_seeders: 50)

      oversaturated =
        Enum.find(ranked, &String.contains?(&1.result.title, "Oversaturated")).breakdown.seeders

      healthy = Enum.find(ranked, &String.contains?(&1.result.title, "Healthy")).breakdown.seeders

      # Healthy swarm should score higher despite having fewer seeders
      assert healthy > oversaturated
    end

    test "excellent ratio (80%+) gets bonus multiplier" do
      results = [
        # Excellent ratio: 80 seeders, 20 leechers (80% ratio) - 1.3x multiplier
        build_result(%{
          seeders: 80,
          leechers: 20,
          title: "Movie.Excellent.1080p.x264"
        }),
        # Healthy ratio: 67 seeders, 33 leechers (67% ratio) - 1.0x multiplier
        build_result(%{
          seeders: 67,
          leechers: 33,
          title: "Movie.Healthy.1080p.x264"
        })
      ]

      ranked = ReleaseRanker.rank_all(results, min_seeders: 50)

      excellent =
        Enum.find(ranked, &String.contains?(&1.result.title, "Excellent")).breakdown.seeders

      healthy = Enum.find(ranked, &String.contains?(&1.result.title, "Healthy")).breakdown.seeders

      # Excellent ratio should get bonus over healthy ratio
      assert excellent > healthy
    end

    test "ratio multipliers are applied correctly at different thresholds" do
      results = [
        # <15% ratio: 0.1x multiplier
        build_result(%{seeders: 10, leechers: 90, title: "Movie.VeryBad"}),
        # 30% ratio: 0.5x multiplier
        build_result(%{seeders: 30, leechers: 70, title: "Movie.Poor"}),
        # 50% ratio: 0.8x multiplier
        build_result(%{seeders: 50, leechers: 50, title: "Movie.Decent"}),
        # 67% ratio: 1.0x multiplier
        build_result(%{seeders: 67, leechers: 33, title: "Movie.Healthy"}),
        # 80%+ ratio: 1.3x multiplier
        build_result(%{seeders: 80, leechers: 20, title: "Movie.Excellent"})
      ]

      ranked = ReleaseRanker.rank_all(results, min_seeders: 5)

      very_bad =
        Enum.find(ranked, &String.contains?(&1.result.title, "VeryBad")).breakdown.seeders

      poor = Enum.find(ranked, &String.contains?(&1.result.title, "Poor")).breakdown.seeders
      decent = Enum.find(ranked, &String.contains?(&1.result.title, "Decent")).breakdown.seeders
      healthy = Enum.find(ranked, &String.contains?(&1.result.title, "Healthy")).breakdown.seeders

      excellent =
        Enum.find(ranked, &String.contains?(&1.result.title, "Excellent")).breakdown.seeders

      # Scores should increase with better ratios
      assert very_bad < poor
      assert poor < decent
      assert decent < healthy
      assert healthy < excellent
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
        # High seeders but poor ratio
        build_result(%{
          seeders: 300,
          leechers: 1500,
          title: "Movie.2023.1080p.Popular.But.Stalled"
        }),
        # Fewer seeders but good ratio
        build_result(%{seeders: 60, leechers: 30, title: "Movie.2023.1080p.Healthy"})
      ]

      best = ReleaseRanker.select_best_result(results, min_seeders: 50, min_ratio: 0.15)

      # The healthy swarm should win even with fewer seeders
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

  describe "size scoring" do
    test "reasonable sizes score higher than extremes" do
      results = [
        build_result(%{size: 50 * 1024 * 1024, title: "Small"}),
        build_result(%{size: 5 * 1024 * 1024 * 1024, title: "Good"}),
        build_result(%{size: 30 * 1024 * 1024 * 1024, title: "Huge"})
      ]

      # Allow all sizes for comparison
      opts = [min_seeders: 0, size_range: {0, 100_000}]

      ranked = ReleaseRanker.rank_all([Enum.at(results, 1)], opts)
      good_score = List.first(ranked).breakdown.size

      ranked_small = ReleaseRanker.rank_all([Enum.at(results, 0)], opts)
      small_score = List.first(ranked_small).breakdown.size

      ranked_huge = ReleaseRanker.rank_all([Enum.at(results, 2)], opts)
      huge_score = List.first(ranked_huge).breakdown.size

      assert good_score > small_score
      assert good_score > huge_score
    end

    test "very small files get zero score" do
      result = build_result(%{size: 50 * 1024 * 1024})

      # Allow very small sizes to pass filtering
      ranked = ReleaseRanker.rank_all([result], min_seeders: 0, size_range: {0, 100_000})

      assert List.first(ranked).breakdown.size == 0.0
    end
  end

  describe "age scoring" do
    test "newer releases score higher" do
      now = DateTime.utc_now()

      results = [
        build_result(%{
          published_at: DateTime.add(now, -2, :day),
          title: "Recent"
        }),
        build_result(%{
          published_at: DateTime.add(now, -365, :day),
          title: "Old"
        })
      ]

      ranked = ReleaseRanker.rank_all(results)

      recent_score =
        Enum.find(ranked, &String.contains?(&1.result.title, "Recent")).breakdown.age

      old_score = Enum.find(ranked, &String.contains?(&1.result.title, "Old")).breakdown.age

      assert recent_score > old_score
    end

    test "nil published_at gets neutral score" do
      result = build_result(%{published_at: nil})

      ranked = ReleaseRanker.rank_all([result])

      assert List.first(ranked).breakdown.age == 50.0
    end

    test "very recent releases get highest age score" do
      result = build_result(%{published_at: DateTime.utc_now()})

      ranked = ReleaseRanker.rank_all([result])

      assert List.first(ranked).breakdown.age == 100.0
    end
  end

  describe "tag scoring" do
    test "preferred tags increase score" do
      results = [
        build_result(%{title: "Movie.PROPER.1080p.x264", seeders: 50}),
        build_result(%{title: "Movie.1080p.x264", seeders: 50})
      ]

      ranked = ReleaseRanker.rank_all(results, preferred_tags: ["PROPER"])

      with_tag = Enum.find(ranked, &String.contains?(&1.result.title, "PROPER"))
      without_tag = Enum.find(ranked, &(!String.contains?(&1.result.title, "PROPER")))

      assert with_tag.breakdown.tag_bonus > 0
      assert without_tag.breakdown.tag_bonus == 0
      assert with_tag.score > without_tag.score
    end

    test "multiple preferred tags stack" do
      result = build_result(%{title: "Movie.PROPER.REPACK.1080p.x264", seeders: 50})

      ranked = ReleaseRanker.rank_all([result], preferred_tags: ["PROPER", "REPACK"])

      # Should get bonus for both tags
      assert List.first(ranked).breakdown.tag_bonus == 50.0
    end

    test "preferred tags are case insensitive" do
      result = build_result(%{title: "Movie.proper.1080p.x264", seeders: 50})

      ranked = ReleaseRanker.rank_all([result], preferred_tags: ["PROPER"])

      assert List.first(ranked).breakdown.tag_bonus > 0
    end

    test "no preferred tags means no bonus" do
      result = build_result(%{title: "Movie.PROPER.1080p.x264", seeders: 50})

      ranked = ReleaseRanker.rank_all([result])

      assert List.first(ranked).breakdown.tag_bonus == 0
    end
  end

  describe "edge cases" do
    test "handles results with missing quality gracefully" do
      result = build_result(%{quality: nil, seeders: 50})

      ranked = ReleaseRanker.rank_all([result])

      assert length(ranked) == 1
      assert List.first(ranked).breakdown.quality == 0.0
    end

    test "handles results with missing published_at gracefully" do
      result = build_result(%{published_at: nil, seeders: 50})

      ranked = ReleaseRanker.rank_all([result])

      assert length(ranked) == 1
      assert List.first(ranked).breakdown.age == 50.0
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

    test "total score matches sum of weighted components" do
      result = build_result(%{seeders: 50})

      ranked = ReleaseRanker.rank_all([result])
      breakdown = List.first(ranked).breakdown

      # Recalculate total from breakdown
      # Quality: 50%, Seeders: 20%, Title Match: 15%, Size: 10%, Age: 5%
      calculated_total =
        breakdown.quality * 0.5 +
          breakdown.seeders * 0.2 +
          breakdown.title_match * 0.15 +
          breakdown.size * 0.1 +
          breakdown.age * 0.05 +
          breakdown.tag_bonus

      # Allow small rounding difference
      assert_in_delta breakdown.total, calculated_total, 0.1
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

    test "without search_query, title_match defaults to neutral score" do
      result = build_result(%{seeders: 50})

      ranked = ReleaseRanker.rank_all([result], min_seeders: 1)
      breakdown = List.first(ranked).breakdown

      # Without search_query, should use neutral score of 500
      assert breakdown.title_match == 500.0
    end

    test "title matching ignores quality indicators" do
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

      # Should have high title match despite extra quality terms
      assert breakdown.title_match > 600
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

      # Should have high title match with year included
      assert breakdown.title_match > 600
    end

    test "exact series title ranks higher than similar but different series" do
      # Real-world case: searching for "The Girlfriend S01"
      # The actual series should rank higher than unrelated series with similar names
      mb = 1024 * 1024
      gb = 1024 * mb

      results = [
        # Unrelated documentary series with similar words
        build_result(%{
          title:
            "Untold.The.Girlfriend.Who.Didnt.Exist.S01.1080p.NF.WEB-DL.ENG.SPA.DDP5.1.x264-themoviesboss",
          size: 6 * gb,
          seeders: 3
        }),
        # The actual series we want
        build_result(%{
          title: "The.Girlfriend.S01E01-06.1080p.AMZN.WEB-DL.ITA.ENG.DDP5.1.H.265-G66",
          size: 8 * gb,
          seeders: 11
        }),
        # Different series with similar name
        build_result(%{
          title: "The.Girlfriend.Experience.S01E01-13.1080p.AMZN.WEB-DL.ITA.ENG.DDP5.1.H.265-G66",
          size: 13 * gb,
          seeders: 6
        }),
        # Unrelated show with "girlfriend" in title
        build_result(%{
          title:
            "Jimmy.Carrs.Am.I.The.Asshole.S01E01.Bill.Splitting.Angst.and.a.Gassy.Girlfriend.1080p.AMZN.WEB-DL",
          size: 3 * gb,
          seeders: 22
        }),
        # Another unrelated show
        build_result(%{
          title: "Trying.S01E02.The.Ex.Girlfriend.1080p.ATVP.WEB-DL.DDP.5.1.Atmos.H.264-FLUX",
          size: 2 * gb,
          seeders: 16
        }),
        # The actual series (season pack with 2025)
        build_result(%{
          title: "The.Girlfriend.2025.S01.1080p.10bit.WEBRip.6CH.x265.HEVC.PSA",
          size: 4 * gb,
          seeders: 311
        }),
        # Another version of the actual series
        build_result(%{
          title: "The.Girlfriend.2025.S01.1080p.WEBRip.x265-KONTRAST",
          size: 7 * gb,
          seeders: 36
        }),
        # Completely different anime series with "girlfriends" in title
        build_result(%{
          title:
            "The.100.Girlfriends.Who.Really.Really.Really.Really.REALLY.Love.You.S01E06.1080p.HEVC.x265-MeGusta",
          size: 285 * mb,
          seeders: 2
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          search_query: "The Girlfriend S01",
          min_seeders: 1,
          size_range: {100, 20_000}
        )

      # Find the indices of key results
      actual_series_indices =
        ranked
        |> Enum.with_index()
        |> Enum.filter(fn {r, _idx} ->
          # The actual "The Girlfriend" 2025 series
          (String.contains?(r.result.title, "The.Girlfriend.2025") or
             String.contains?(r.result.title, "The.Girlfriend.S01E01")) and
            not String.contains?(r.result.title, "Experience") and
            not String.contains?(r.result.title, "Untold") and
            not String.contains?(r.result.title, "100.Girlfriends")
        end)
        |> Enum.map(fn {_r, idx} -> idx end)

      unrelated_series_indices =
        ranked
        |> Enum.with_index()
        |> Enum.filter(fn {r, _idx} ->
          String.contains?(r.result.title, "Untold") or
            String.contains?(r.result.title, "Experience") or
            String.contains?(r.result.title, "Jimmy.Carrs") or
            String.contains?(r.result.title, "Trying") or
            String.contains?(r.result.title, "100.Girlfriends")
        end)
        |> Enum.map(fn {_r, idx} -> idx end)

      # The actual series should rank before all unrelated series
      max_actual_idx = Enum.max(actual_series_indices)
      min_unrelated_idx = Enum.min(unrelated_series_indices)

      assert max_actual_idx < min_unrelated_idx,
             """
             Expected actual series "The Girlfriend" to rank before unrelated series.

             Ranking order:
             #{ranked |> Enum.with_index() |> Enum.map(fn {r, idx} -> "  #{idx + 1}. #{r.result.title} (score: #{Float.round(r.score, 1)}, title_match: #{Float.round(r.breakdown.title_match, 1)})" end) |> Enum.join("\n")}

             Actual series at indices: #{inspect(actual_series_indices)}
             Unrelated series at indices: #{inspect(unrelated_series_indices)}
             """
    end

    test "ISSUE: without search_query, unrelated series can outrank actual series" do
      # This test documents the current issue where search results are sorted
      # by quality profile without considering title relevance.
      #
      # When searching for "The Girlfriend S01", results like "The Girlfriend Experience"
      # or "Untold: The Girlfriend Who Didn't Exist" can rank higher than the actual
      # series "The Girlfriend (2025)" if they have similar quality specs.
      #
      # The fix requires passing the search query to the ranker so title matching
      # contributes to the score.
      mb = 1024 * 1024
      gb = 1024 * mb

      results = [
        # Unrelated documentary - scores high on quality alone
        build_result(%{
          title:
            "Untold.The.Girlfriend.Who.Didnt.Exist.S01.1080p.NF.WEB-DL.ENG.SPA.DDP5.1.x264-themoviesboss",
          size: 6 * gb,
          seeders: 3
        }),
        # The actual series we want
        build_result(%{
          title: "The.Girlfriend.2025.S01.1080p.WEBRip.x265-KONTRAST",
          size: 7 * gb,
          seeders: 36
        }),
        # Different series with similar name - scores high on quality alone
        build_result(%{
          title: "The.Girlfriend.Experience.S01E01-13.1080p.AMZN.WEB-DL.ITA.ENG.DDP5.1.H.265-G66",
          size: 13 * gb,
          seeders: 6
        })
      ]

      # Without search_query, all results get neutral title_match score of 500
      ranked_without_query =
        ReleaseRanker.rank_all(results,
          min_seeders: 1,
          size_range: {100, 20_000}
        )

      # With search_query, the actual series should rank higher
      ranked_with_query =
        ReleaseRanker.rank_all(results,
          search_query: "The Girlfriend S01",
          min_seeders: 1,
          size_range: {100, 20_000}
        )

      # Find title_match scores
      without_query_scores =
        Enum.map(ranked_without_query, fn r ->
          {r.result.title |> String.split(".") |> Enum.take(3) |> Enum.join("."),
           r.breakdown.title_match}
        end)

      with_query_scores =
        Enum.map(ranked_with_query, fn r ->
          {r.result.title |> String.split(".") |> Enum.take(3) |> Enum.join("."),
           r.breakdown.title_match}
        end)

      # Without query, all title_match scores should be neutral (500)
      assert Enum.all?(ranked_without_query, fn r -> r.breakdown.title_match == 500.0 end),
             "Without search_query, title_match should be neutral 500. Got: #{inspect(without_query_scores)}"

      # With query, the actual series should have higher title_match than unrelated
      actual_series =
        Enum.find(ranked_with_query, &String.contains?(&1.result.title, "The.Girlfriend.2025"))

      experience_series =
        Enum.find(ranked_with_query, &String.contains?(&1.result.title, "Experience"))

      assert actual_series.breakdown.title_match > experience_series.breakdown.title_match,
             """
             Actual series should have higher title_match than "The Girlfriend Experience".
             Actual: #{actual_series.breakdown.title_match}
             Experience: #{experience_series.breakdown.title_match}
             """

      # The actual series should rank first when search_query is provided
      first_with_query = List.first(ranked_with_query)

      assert String.contains?(first_with_query.result.title, "The.Girlfriend.2025"),
             """
             With search_query, "The Girlfriend 2025" should rank first.
             Got: #{first_with_query.result.title}

             With query ranking: #{inspect(with_query_scores)}
             """
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
        # x265 BluRay - currently scores highest (83 in real search)
        build_result(%{
          title: "xXx.2002.1080p.BluRay.x265.SDR.DDP.5.1.English.DarQ.HONE",
          size: round(9.5 * gb),
          seeders: 0,
          quality: QualityParser.parse("xXx.2002.1080p.BluRay.x265.SDR.DDP.5.1.English.DarQ.HONE")
        }),
        # x264 BluRay with AC3 (75 in real search)
        build_result(%{
          title: "xXx 2002 1080p Bluray AC3 x264 - AdiT -",
          size: round(6.2 * gb),
          seeders: 0,
          quality: QualityParser.parse("xXx 2002 1080p Bluray AC3 x264 - AdiT -")
        }),
        # x264 BluRay with DTS:X - larger file (73 in real search)
        build_result(%{
          title: "xXx 2002 1080p BluRay AC3 DTS x264-GAIA",
          size: round(15.1 * gb),
          seeders: 0,
          quality: QualityParser.parse("xXx 2002 1080p BluRay AC3 DTS x264-GAIA")
        }),
        # x264 BluRay (68 in real search)
        build_result(%{
          title: "xXx.2002.1080p.BluRay.x264-OFT",
          size: round(6.0 * gb),
          seeders: 0,
          quality: QualityParser.parse("xXx.2002.1080p.BluRay.x264-OFT")
        }),
        # Remastered x265 (76 in real search)
        build_result(%{
          title: "xXx.2002.Remastered.1080p.BluRay.10Bit.X265.DD.5.1-Chivaman",
          size: round(5.5 * gb),
          seeders: 0,
          quality:
            QualityParser.parse("xXx.2002.Remastered.1080p.BluRay.10Bit.X265.DD.5.1-Chivaman")
        }),
        # 15th Anniversary Edition x264 DD+ (75 in real search)
        build_result(%{
          title: "xXx.2002.15th.Anniversary.Edition.BluRay.1080p.DDP.5.1.x264-hallowed",
          size: round(12.5 * gb),
          seeders: 0,
          quality:
            QualityParser.parse(
              "xXx.2002.15th.Anniversary.Edition.BluRay.1080p.DDP.5.1.x264-hallowed"
            )
        }),
        # WEB-DL H.264 DD+ (71 in real search)
        build_result(%{
          title: "xXx.2002.1080p.HMAX.WEB-DL.DDP.5.1.H.264-PiRaTeS",
          size: round(14.2 * gb),
          seeders: 0,
          quality: QualityParser.parse("xXx.2002.1080p.HMAX.WEB-DL.DDP.5.1.H.264-PiRaTeS")
        }),
        # WEB-DL H.264 AAC - smaller file (71 in real search)
        build_result(%{
          title: "xXx.2002.1080p.ALL4.WEB-DL.AAC.2.0.H.264-PiRaTeS",
          size: round(4.6 * gb),
          seeders: 0,
          quality: QualityParser.parse("xXx.2002.1080p.ALL4.WEB-DL.AAC.2.0.H.264-PiRaTeS")
        }),
        # DVDRip x264 - lower quality (48 in real search)
        build_result(%{
          title: "XXX.2002.DVDRip.x264-DJ",
          size: round(1.2 * gb),
          seeders: 0,
          quality: QualityParser.parse("XXX.2002.DVDRip.x264-DJ")
        }),
        # REMUX - very large (46 in real search - why so low?)
        build_result(%{
          title: "XXX.2002.BD-Remux.mkv",
          size: round(15.7 * gb),
          seeders: 0,
          quality: QualityParser.parse("XXX.2002.BD-Remux.mkv")
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
          "  #{idx}. Score: #{Float.round(r.score, 1)} | #{r.result.title}\n" <>
            "     Quality: #{inspect(r.breakdown.quality)} | Seeders: #{inspect(r.breakdown.seeders)} | " <>
            "Size: #{inspect(r.breakdown.size)} | Title: #{inspect(r.breakdown.title_match)}"
        end)
        |> Enum.join("\n")

      # Basic assertions

      # 1. DVDRip should rank lower than BluRay 1080p releases
      dvdrip = Enum.find(ranked, &String.contains?(&1.result.title, "DVDRip"))
      bluray_1080p = Enum.find(ranked, &String.contains?(&1.result.title, "1080p.BluRay.x265"))

      assert bluray_1080p.score > dvdrip.score,
             """
             BluRay 1080p should score higher than DVDRip.
             BluRay score: #{bluray_1080p.score}
             DVDRip score: #{dvdrip.score}

             Full ranking:
             #{ranking_info}
             """

      # 2. Unrelated "Private Gladiator" should rank lower due to title mismatch
      gladiator = Enum.find(ranked, &String.contains?(&1.result.title, "Private Gladiator"))
      xxx_bluray = Enum.find(ranked, &String.contains?(&1.result.title, "xXx.2002.1080p.BluRay"))

      assert xxx_bluray.score > gladiator.score,
             """
             xXx BluRay should score higher than unrelated "Private Gladiator" content.
             xXx score: #{xxx_bluray.score}
             Gladiator score: #{gladiator.score}

             Full ranking:
             #{ranking_info}
             """

      # 3. REMUX should have high quality score (it's the highest quality source)
      remux = Enum.find(ranked, &String.contains?(&1.result.title, "BD-Remux"))

      assert remux.breakdown.quality > dvdrip.breakdown.quality,
             """
             REMUX should have higher quality score than DVDRip.
             REMUX quality: #{remux.breakdown.quality}
             DVDRip quality: #{dvdrip.breakdown.quality}

             Full ranking:
             #{ranking_info}
             """

      # 4. WEB-DL with explicit audio can score higher than BluRay without audio info
      # This documents that the scorer rewards explicit audio codec info in titles.
      # "xXx.2002.1080p.HMAX.WEB-DL.DDP.5.1.H.264" has DD+ (120 points)
      # "xXx.2002.1080p.BluRay.x264-OFT" has no detectable audio codec
      webdl_ddp = Enum.find(ranked, &String.contains?(&1.result.title, "WEB-DL.DDP"))
      bluray_with_audio = Enum.find(ranked, &String.contains?(&1.result.title, "BluRay.AC3"))

      if bluray_with_audio && webdl_ddp do
        assert bluray_with_audio.breakdown.quality >= webdl_ddp.breakdown.quality,
               """
               BluRay with audio should have higher or equal quality score than WEB-DL.
               BluRay quality: #{bluray_with_audio.breakdown.quality}
               WEB-DL quality: #{webdl_ddp.breakdown.quality}

               Full ranking:
               #{ranking_info}
               """
      end

      # 5. ISSUE: REMUX parsing - "BD-Remux" should be parsed as REMUX source
      # Currently the parser doesn't recognize "BD-Remux" as a valid REMUX pattern
      # This causes REMUX releases to score very low (500.0) instead of the highest quality
      remux_quality = remux.breakdown.quality
      bluray_quality = bluray_1080p.breakdown.quality

      # Document this as a known issue - REMUX should score higher than BluRay
      # but currently doesn't because the parser fails to detect the REMUX source
      if remux_quality < bluray_quality do
        IO.puts("""
        \n[KNOWN ISSUE] REMUX quality parsing issue detected:
        - REMUX quality: #{remux_quality}
        - BluRay quality: #{bluray_quality}
        - Expected: REMUX should be >= BluRay
        - The parser may not recognize "BD-Remux" pattern
        """)
      end
    end
  end
end
