defmodule Mydia.Downloads.TorrentMatcher do
  @moduledoc """
  Matches parsed torrent information against library items.

  Uses fuzzy string matching to find the best matching media item
  for a given torrent, along with a confidence score.
  """

  alias Mydia.Media
  alias Mydia.Media.{MediaItem, Episode}

  @type match_result :: %{
          media_item: MediaItem.t(),
          episode: Episode.t() | nil,
          confidence: float(),
          match_reason: String.t()
        }

  @doc """
  Finds the best matching library item for parsed torrent info.

  Returns `{:ok, match}` with the best match above the confidence threshold,
  or `{:error, reason}` if no confident match is found.

  ## Options
    - `:confidence_threshold` - Minimum confidence (0.0 to 1.0) required for a match (default: 0.8)
    - `:monitored_only` - Only match against monitored items (default: true)
  """
  def find_match(torrent_info, opts \\ []) do
    confidence_threshold = Keyword.get(opts, :confidence_threshold, 0.8)
    monitored_only = Keyword.get(opts, :monitored_only, true)

    case torrent_info.type do
      :movie ->
        find_movie_match(torrent_info, monitored_only, confidence_threshold)

      :tv ->
        find_tv_match(torrent_info, monitored_only, confidence_threshold)

      :tv_season ->
        find_tv_season_match(torrent_info, monitored_only, confidence_threshold)
    end
  end

  ## Private Functions - Movie Matching

  defp find_movie_match(torrent_info, monitored_only, threshold) do
    # Get all movies from the library
    movies = list_movies(monitored_only)

    # Find potential matches with similarity scores
    matches =
      movies
      |> Enum.map(fn movie ->
        confidence = calculate_movie_confidence(movie, torrent_info)
        {movie, confidence}
      end)
      |> Enum.filter(fn {_movie, confidence} -> confidence >= threshold end)
      |> Enum.sort_by(fn {_movie, confidence} -> confidence end, :desc)

    case matches do
      [{movie, confidence} | _] ->
        {:ok,
         %{
           media_item: movie,
           episode: nil,
           confidence: confidence,
           match_reason: build_movie_match_reason(movie, torrent_info, confidence)
         }}

      [] ->
        {:error, :no_match_found}
    end
  end

  defp calculate_movie_confidence(movie, torrent_info) do
    # Start with title similarity
    title_similarity =
      string_similarity(normalize_string(movie.title), normalize_string(torrent_info.title))

    # Year matching is critical for movies
    year_match =
      cond do
        # Exact year match - high boost
        movie.year == torrent_info.year -> 0.3
        # Within 1 year (sometimes release dates differ)
        movie.year && abs(movie.year - torrent_info.year) <= 1 -> 0.15
        # No year match
        true -> -0.2
      end

    # Calculate final confidence (weighted average)
    # Title is 70% weight, year is 30% weight (added as boost)
    confidence = title_similarity * 0.7 + year_match

    # Clamp between 0 and 1
    max(0.0, min(1.0, confidence))
  end

  defp build_movie_match_reason(movie, torrent_info, confidence) do
    "Matched '#{torrent_info.title}' (#{torrent_info.year}) to '#{movie.title}' (#{movie.year}) with #{Float.round(confidence * 100, 1)}% confidence"
  end

  ## Private Functions - TV Show Matching

  defp find_tv_match(torrent_info, monitored_only, threshold) do
    # Get all TV shows from the library
    tv_shows = list_tv_shows(monitored_only)

    # Find potential show matches
    show_matches =
      tv_shows
      |> Enum.map(fn show ->
        confidence = calculate_tv_show_confidence(show, torrent_info)
        {show, confidence}
      end)
      |> Enum.filter(fn {_show, confidence} -> confidence >= threshold end)
      |> Enum.sort_by(fn {_show, confidence} -> confidence end, :desc)

    case show_matches do
      [{show, confidence} | _] ->
        # Found a matching show, now find the specific episode
        case find_episode(show, torrent_info) do
          {:ok, episode} ->
            {:ok,
             %{
               media_item: show,
               episode: episode,
               confidence: confidence,
               match_reason: build_tv_match_reason(show, episode, torrent_info, confidence)
             }}

          {:error, :episode_not_found} ->
            {:error, :episode_not_found}
        end

      [] ->
        {:error, :no_match_found}
    end
  end

  defp calculate_tv_show_confidence(show, torrent_info) do
    # For TV shows, we primarily rely on title matching
    # since torrents don't include the show's year
    title_similarity =
      string_similarity(normalize_string(show.title), normalize_string(torrent_info.title))

    # TV show matching is more straightforward - just title similarity
    title_similarity
  end

  defp find_episode(show, torrent_info) do
    case Media.get_episode_by_number(show.id, torrent_info.season, torrent_info.episode) do
      nil -> {:error, :episode_not_found}
      episode -> {:ok, episode}
    end
  end

  defp build_tv_match_reason(show, episode, torrent_info, confidence) do
    "Matched '#{torrent_info.title}' S#{torrent_info.season}E#{torrent_info.episode} to '#{show.title}' S#{episode.season_number}E#{episode.episode_number} with #{Float.round(confidence * 100, 1)}% confidence"
  end

  ## Private Functions - TV Season Pack Matching

  defp find_tv_season_match(torrent_info, monitored_only, threshold) do
    # Get all TV shows from the library
    tv_shows = list_tv_shows(monitored_only)

    # Find potential show matches
    show_matches =
      tv_shows
      |> Enum.map(fn show ->
        confidence = calculate_tv_show_confidence(show, torrent_info)
        {show, confidence}
      end)
      |> Enum.filter(fn {_show, confidence} -> confidence >= threshold end)
      |> Enum.sort_by(fn {_show, confidence} -> confidence end, :desc)

    case show_matches do
      [{show, confidence} | _] ->
        # For season packs, match the show but don't require a specific episode
        {:ok,
         %{
           media_item: show,
           episode: nil,
           confidence: confidence,
           match_reason: build_tv_season_match_reason(show, torrent_info, confidence)
         }}

      [] ->
        {:error, :no_match_found}
    end
  end

  defp build_tv_season_match_reason(show, torrent_info, confidence) do
    "Matched season pack '#{torrent_info.title}' S#{torrent_info.season} to '#{show.title}' with #{Float.round(confidence * 100, 1)}% confidence"
  end

  ## Private Functions - String Similarity

  defp string_similarity(str1, str2) do
    # Use Jaro-Winkler distance for better matching
    # This gives more weight to matching prefixes
    jaro_winkler_distance(str1, str2)
  end

  defp normalize_string(str) do
    str
    |> String.downcase()
    # Remove common words that might cause issues
    |> String.replace(~r/\b(the|a|an)\b/, "")
    # Remove special characters
    |> String.replace(~r/[^\w\s]/, "")
    # Normalize whitespace
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # Jaro-Winkler distance implementation
  # Returns a value between 0.0 (no match) and 1.0 (perfect match)
  defp jaro_winkler_distance(str1, str2) do
    # Handle edge cases
    cond do
      str1 == str2 -> 1.0
      str1 == "" or str2 == "" -> 0.0
      true -> calculate_jaro_winkler(str1, str2)
    end
  end

  defp calculate_jaro_winkler(str1, str2) do
    jaro = jaro_similarity(str1, str2)

    # Jaro-Winkler adds a prefix boost
    prefix_length = common_prefix_length(str1, str2, 4)
    prefix_scale = 0.1

    jaro + prefix_length * prefix_scale * (1.0 - jaro)
  end

  defp jaro_similarity(str1, str2) do
    len1 = String.length(str1)
    len2 = String.length(str2)

    # Match window
    match_distance = max(0, div(max(len1, len2), 2) - 1)

    # Find matches
    {matches1, matches2} = find_matches(str1, str2, match_distance)
    match_count = Enum.count(matches1, & &1)

    if match_count == 0 do
      0.0
    else
      # Count transpositions
      transpositions = count_transpositions(str1, str2, matches1, matches2)

      # Jaro similarity formula
      (match_count / len1 + match_count / len2 + (match_count - transpositions) / match_count) /
        3.0
    end
  end

  defp find_matches(str1, str2, match_distance) do
    chars1 = String.graphemes(str1)
    chars2 = String.graphemes(str2)

    # Initialize match arrays
    matches1 = List.duplicate(false, length(chars1))
    matches2 = List.duplicate(false, length(chars2))

    # Find matches
    {matches1, matches2} =
      Enum.reduce(Enum.with_index(chars1), {matches1, matches2}, fn {char1, i}, {m1, m2} ->
        start = max(0, i - match_distance)
        stop = min(i + match_distance + 1, length(chars2))

        case find_match_in_range(char1, chars2, m2, start, stop) do
          nil ->
            {m1, m2}

          j ->
            {List.replace_at(m1, i, true), List.replace_at(m2, j, true)}
        end
      end)

    {matches1, matches2}
  end

  defp find_match_in_range(char, chars, matches, start, stop) do
    Enum.find(start..(stop - 1)//1, fn j ->
      not Enum.at(matches, j) and Enum.at(chars, j) == char
    end)
  end

  defp count_transpositions(str1, str2, matches1, matches2) do
    chars1 = String.graphemes(str1)
    chars2 = String.graphemes(str2)

    # Get matched characters in order
    matched_chars1 =
      matches1
      |> Enum.with_index()
      |> Enum.filter(fn {match, _} -> match end)
      |> Enum.map(fn {_, i} -> Enum.at(chars1, i) end)

    matched_chars2 =
      matches2
      |> Enum.with_index()
      |> Enum.filter(fn {match, _} -> match end)
      |> Enum.map(fn {_, i} -> Enum.at(chars2, i) end)

    # Count transpositions
    Enum.zip(matched_chars1, matched_chars2)
    |> Enum.count(fn {c1, c2} -> c1 != c2 end)
    |> div(2)
  end

  defp common_prefix_length(str1, str2, max_length) do
    chars1 = String.graphemes(str1)
    chars2 = String.graphemes(str2)

    Enum.zip(chars1, chars2)
    |> Enum.take(max_length)
    |> Enum.take_while(fn {c1, c2} -> c1 == c2 end)
    |> length()
  end

  ## Private Functions - Library Queries

  defp list_movies(monitored_only) do
    opts =
      if monitored_only do
        [type: "movie", monitored: true]
      else
        [type: "movie"]
      end

    Media.list_media_items(opts)
  end

  defp list_tv_shows(monitored_only) do
    opts =
      if monitored_only do
        [type: "tv_show", monitored: true]
      else
        [type: "tv_show"]
      end

    Media.list_media_items(opts)
  end
end
