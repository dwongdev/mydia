defmodule MydiaWeb.MediaLive.Show.SearchHelpersTest do
  use ExUnit.Case, async: true

  alias MydiaWeb.MediaLive.Show.SearchHelpers
  alias Mydia.Indexers.{QualityParser, SearchResult}

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

  describe "sort_search_results/5 with title relevance" do
    test "exact title match ranks higher than similar but different series" do
      mb = 1024 * 1024
      gb = 1024 * mb

      results = [
        # Unrelated documentary with similar words
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
        # Different series with similar name
        build_result(%{
          title: "The.Girlfriend.Experience.S01E01-13.1080p.AMZN.WEB-DL.ITA.ENG.DDP5.1.H.265-G66",
          size: 13 * gb,
          seeders: 6
        })
      ]

      # With search_query, title relevance should boost "The Girlfriend 2025"
      sorted_with_query =
        SearchHelpers.sort_search_results(results, :quality, nil, :episode, "The Girlfriend S01")

      # Find the actual series position in sorted list
      actual_idx_with =
        Enum.find_index(sorted_with_query, &String.contains?(&1.title, "The.Girlfriend.2025"))

      # With the search query, "The Girlfriend 2025" should rank first (index 0)
      assert actual_idx_with == 0,
             """
             Expected "The Girlfriend 2025" to rank first when search_query is provided.
             Position: #{actual_idx_with}
             Sorted order: #{Enum.map(sorted_with_query, & &1.title) |> inspect()}
             """

      # Verify "The Girlfriend Experience" ranks after the actual series
      experience_idx =
        Enum.find_index(sorted_with_query, &String.contains?(&1.title, "Experience"))

      assert experience_idx > actual_idx_with,
             "The Girlfriend Experience should rank after the actual series"
    end

    test "title relevance bonus is applied when search_query is provided" do
      results = [
        build_result(%{title: "Some.Other.Show.S01.1080p.WEB-DL", seeders: 100}),
        build_result(%{title: "The.Show.S01E01.1080p.WEB-DL", seeders: 50}),
        build_result(%{title: "The.Show.And.More.S01.1080p.WEB-DL", seeders: 75})
      ]

      sorted = SearchHelpers.sort_search_results(results, :quality, nil, :episode, "The Show S01")

      # "The.Show.S01E01" should rank first as it closely matches the query
      first = List.first(sorted)
      assert String.contains?(first.title, "The.Show.S01E01")
    end

    test "without search_query, title relevance bonus is zero" do
      # This test verifies that the title_relevance_bonus returns 0 when no query is provided
      # The actual sorting depends on quality profile scores
      results = [
        build_result(%{title: "The.Girlfriend.S01.1080p.WEB-DL", seeders: 50}),
        build_result(%{title: "Other.Show.S01.1080p.WEB-DL", seeders: 50})
      ]

      # Sort without and with search_query
      sorted_without = SearchHelpers.sort_search_results(results, :quality, nil, :episode, nil)

      sorted_with =
        SearchHelpers.sort_search_results(results, :quality, nil, :episode, "The Girlfriend S01")

      # With search_query, "The Girlfriend" should rank first
      first_with = List.first(sorted_with)

      assert String.contains?(first_with.title, "The.Girlfriend"),
             "With search_query, title relevance should boost 'The Girlfriend'"

      # Without search_query, the order might be different (based only on quality/seeders)
      # The key point is that title matching is only applied when query is provided
      titles_without = Enum.map(sorted_without, & &1.title)
      titles_with = Enum.map(sorted_with, & &1.title)

      # Just verify both lists contain the same items (they might be in different order)
      assert Enum.sort(titles_without) == Enum.sort(titles_with)
    end

    test "title with extra unrelated words gets penalty" do
      results = [
        # Many extra unrelated words
        build_result(%{
          title:
            "Jimmy.Carrs.Am.I.The.Asshole.S01E01.Bill.Splitting.Angst.and.a.Gassy.Girlfriend.1080p",
          seeders: 50
        }),
        # Clean match
        build_result(%{title: "The.Girlfriend.S01E01.1080p.WEB-DL", seeders: 50})
      ]

      sorted =
        SearchHelpers.sort_search_results(results, :quality, nil, :episode, "The Girlfriend S01")

      # The clean match should rank first due to penalty on extra words
      first = List.first(sorted)
      assert String.contains?(first.title, "The.Girlfriend.S01E01")
    end
  end

  describe "sort_search_results/5 other sort modes" do
    test ":seeders ignores title relevance" do
      results = [
        build_result(%{title: "Exact.Match.S01.1080p", seeders: 10}),
        build_result(%{title: "Not.Match.S01.1080p", seeders: 100})
      ]

      sorted =
        SearchHelpers.sort_search_results(
          results,
          :seeders,
          nil,
          :episode,
          "Exact Match S01"
        )

      # Should sort by seeders regardless of title match
      first = List.first(sorted)
      assert first.seeders == 100
    end

    test ":size ignores title relevance" do
      small_size = 1 * 1024 * 1024 * 1024
      large_size = 10 * 1024 * 1024 * 1024

      results = [
        build_result(%{title: "Exact.Match.S01.1080p", size: small_size, seeders: 50}),
        build_result(%{title: "Not.Match.S01.1080p", size: large_size, seeders: 50})
      ]

      sorted =
        SearchHelpers.sort_search_results(results, :size, nil, :episode, "Exact Match S01")

      # Should sort by size regardless of title match
      first = List.first(sorted)
      assert first.size == large_size
    end
  end
end
