#!/usr/bin/env elixir

# Test script to investigate metadata matching issues
# Run with: ./dev mix run test_metadata_matching.exs

require Logger

# Add test filenames
test_files = [
  "Robin.Hood.2025.S01E01.1080p.HEVC.x265-MeGusta[EZTVx.to].mkv",
  "Robin.Hood.2025.S01E02.1080p.HEVC.x265-MeGusta[EZTVx.to].mkv",
  "Robin.Hood.2025.S01E03.Nessuno.puo.restare.nascosto.per.sempre.ITA.ENG.1080p.AMZN.WEB-DL.DDP5.1.H.264-MeM.GP.mkv",
  "Severance.S01E01.Good.News.About.Hell.2160p.10bit.ATVP.WEB-DL.DDP5.1.HEVC-Vyndros.mkv",
  "Severance.S01E02.Half.Loop.2160p.10bit.ATVP.WEB-DL.DDP5.1.HEVC-Vyndros.mkv",
  "Stranger.Things.S01E01.Capitolo.Primo.La.scomparsa.di.Will.Byers.ITA.ENG.2160p.NF.WEB-DL.DDP5.1.DV.HDR.H.265-MeM.GP.mkv",
  "Stranger.Things.S01E02.ITA.ENG.2160p.NF.WEB-DL.DDP5.1.DV.HDR.H.265-MeM.GP.mkv"
]

alias Mydia.Library.FileParser.V2, as: FileParser
alias Mydia.Library.MetadataMatcher
alias Mydia.Metadata

IO.puts("\n=== Testing File Parsing and Metadata Matching ===\n")

config = Metadata.default_relay_config()

Enum.each(test_files, fn filename ->
  IO.puts("Testing: #{filename}")
  IO.puts(String.duplicate("-", 80))

  # Parse the filename
  parsed = FileParser.parse(filename)

  IO.puts("  Parsed:")
  IO.puts("    Type: #{parsed.type}")
  IO.puts("    Title: #{parsed.title}")
  IO.puts("    Year: #{inspect(parsed.year)}")
  IO.puts("    Season: #{inspect(parsed.season)}")
  IO.puts("    Episodes: #{inspect(parsed.episodes)}")
  IO.puts("    Confidence: #{parsed.confidence}")

  # Try to match with metadata
  IO.puts("\n  Attempting metadata match...")

  case MetadataMatcher.match_file(filename, config: config) do
    {:ok, match} ->
      IO.puts("    ✓ MATCHED!")
      IO.puts("    Provider ID: #{match.provider_id}")
      IO.puts("    Title: #{match.title}")
      IO.puts("    Year: #{inspect(match.year)}")
      IO.puts("    Confidence: #{match.match_confidence}")

      if match.match_type do
        IO.puts("    Match Type: #{match.match_type}")
      end

      if match.partial_reason do
        IO.puts("    Partial Reason: #{match.partial_reason}")
      end

    {:error, reason} ->
      IO.puts("    ✗ NO MATCH")
      IO.puts("    Reason: #{inspect(reason)}")

      # Try to manually search to see what we get
      if parsed.title do
        IO.puts("\n  Manually searching for '#{parsed.title}'...")

        search_opts = [media_type: :tv_show]

        search_opts =
          if parsed.year, do: Keyword.put(search_opts, :year, parsed.year), else: search_opts

        case Metadata.search(config, parsed.title, search_opts) do
          {:ok, results} ->
            IO.puts("    Found #{length(results)} results:")

            results
            |> Enum.take(3)
            |> Enum.each(fn result ->
              IO.puts(
                "      - #{result.title} (#{result.year}) [ID: #{result.provider_id}, Pop: #{result.popularity}]"
              )
            end)

          {:error, search_error} ->
            IO.puts("    Search error: #{inspect(search_error)}")
        end

        # Also try without year
        if parsed.year do
          IO.puts("\n  Searching without year...")

          case Metadata.search(config, parsed.title, media_type: :tv_show) do
            {:ok, results} ->
              IO.puts("    Found #{length(results)} results:")

              results
              |> Enum.take(3)
              |> Enum.each(fn result ->
                IO.puts(
                  "      - #{result.title} (#{result.year}) [ID: #{result.provider_id}, Pop: #{result.popularity}]"
                )
              end)

            {:error, search_error} ->
              IO.puts("    Search error: #{inspect(search_error)}")
          end
        end
      end
  end

  IO.puts("\n")
end)

IO.puts("=== Test Complete ===\n")
