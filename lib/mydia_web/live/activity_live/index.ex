defmodule MydiaWeb.ActivityLive.Index do
  use MydiaWeb, :live_view
  alias Mydia.Events
  alias Phoenix.PubSub

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    socket =
      if connected?(socket) do
        # Subscribe to events for real-time updates
        PubSub.subscribe(Mydia.PubSub, "events:all")

        socket
        |> assign(:category_filter, "all")
        |> assign(:date_filter, "all")
        |> assign(:page, 0)
        |> assign(:has_more?, false)
        |> assign(:events_empty?, false)
        |> load_events()
      else
        socket
        |> assign(:category_filter, "all")
        |> assign(:date_filter, "all")
        |> assign(:page, 0)
        |> assign(:has_more?, false)
        |> assign(:events_empty?, true)
        |> stream(:events, [])
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply,
     socket
     |> assign(:page_title, "Activity")}
  end

  @impl true
  def handle_event("filter_category", %{"category" => category}, socket) do
    {:noreply,
     socket
     |> assign(:category_filter, category)
     |> assign(:page, 0)
     |> load_events()}
  end

  @impl true
  def handle_event("filter_date", %{"date" => date_preset}, socket) do
    {:noreply,
     socket
     |> assign(:date_filter, date_preset)
     |> assign(:page, 0)
     |> load_events()}
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    next_page = socket.assigns.page + 1

    {:noreply,
     socket
     |> assign(:page, next_page)
     |> load_more_events()}
  end

  @impl true
  def handle_info({:event_created, event}, socket) do
    category_filter = socket.assigns.category_filter
    date_filter = socket.assigns.date_filter

    # Only add event if it matches current category filter
    matches_category =
      case category_filter do
        "all" -> true
        "errors" -> event.severity == :error
        category -> event.category == category
      end

    # Only add event if it matches current date filter
    matches_date = event_matches_date_filter?(event.inserted_at, date_filter)

    socket =
      if matches_category && matches_date do
        socket
        |> assign(:events_empty?, false)
        |> stream_insert(:events, event, at: 0)
      else
        socket
      end

    {:noreply, socket}
  end

  ## Private Helpers

  defp load_events(socket) do
    category_filter = socket.assigns.category_filter
    date_filter = socket.assigns.date_filter

    filter_opts = build_filter_opts(category_filter, date_filter)

    # Request one more than page_size to check if there are more results
    events = Events.list_events(filter_opts ++ [limit: @page_size + 1, offset: 0])

    has_more? = length(events) > @page_size
    events = Enum.take(events, @page_size)

    socket
    |> assign(:events_empty?, events == [])
    |> assign(:has_more?, has_more?)
    |> stream(:events, events, reset: true)
  end

  defp load_more_events(socket) do
    category_filter = socket.assigns.category_filter
    date_filter = socket.assigns.date_filter
    page = socket.assigns.page

    filter_opts = build_filter_opts(category_filter, date_filter)
    offset = page * @page_size

    # Request one more than page_size to check if there are more results
    events = Events.list_events(filter_opts ++ [limit: @page_size + 1, offset: offset])

    has_more? = length(events) > @page_size
    events = Enum.take(events, @page_size)

    socket =
      Enum.reduce(events, socket, fn event, acc ->
        stream_insert(acc, :events, event)
      end)

    assign(socket, :has_more?, has_more?)
  end

  defp build_filter_opts(category_filter, date_filter) do
    category_opts =
      case category_filter do
        "all" -> []
        "errors" -> [severity: :error]
        category -> [category: category]
      end

    date_opts = date_filter_opts(date_filter)

    category_opts ++ date_opts
  end

  defp date_filter_opts("all"), do: []
  defp date_filter_opts("today"), do: [since: start_of_day()]

  defp date_filter_opts("yesterday") do
    [since: start_of_yesterday(), until: end_of_yesterday()]
  end

  defp date_filter_opts("week"), do: [since: days_ago(7)]
  defp date_filter_opts("month"), do: [since: days_ago(30)]
  defp date_filter_opts(_), do: []

  defp start_of_day do
    DateTime.utc_now()
    |> DateTime.to_date()
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end

  defp start_of_yesterday do
    DateTime.utc_now()
    |> DateTime.add(-1, :day)
    |> DateTime.to_date()
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end

  defp end_of_yesterday do
    DateTime.utc_now()
    |> DateTime.to_date()
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end

  defp days_ago(n) do
    DateTime.utc_now() |> DateTime.add(-n, :day)
  end

  defp event_matches_date_filter?(_inserted_at, "all"), do: true

  defp event_matches_date_filter?(inserted_at, "today") do
    DateTime.compare(inserted_at, start_of_day()) != :lt
  end

  defp event_matches_date_filter?(inserted_at, "yesterday") do
    DateTime.compare(inserted_at, start_of_yesterday()) != :lt &&
      DateTime.compare(inserted_at, end_of_yesterday()) == :lt
  end

  defp event_matches_date_filter?(inserted_at, "week") do
    DateTime.compare(inserted_at, days_ago(7)) != :lt
  end

  defp event_matches_date_filter?(inserted_at, "month") do
    DateTime.compare(inserted_at, days_ago(30)) != :lt
  end

  defp event_matches_date_filter?(_inserted_at, _), do: true

  ## UI Helpers

  defp format_event_description(event) do
    case event.type do
      "media_item.added" ->
        title = event.metadata["title"] || "Unknown"
        media_type = event.metadata["media_type"]
        type_label = if media_type == "movie", do: "movie", else: "TV show"
        "Added #{type_label}: #{title}"

      "media_item.updated" ->
        title = event.metadata["title"] || "Unknown"
        reason = event.metadata["reason"] || "Updated"
        changes_summary = format_changes_summary(event.metadata["changes"])

        if changes_summary do
          "#{reason}: #{title} (#{changes_summary})"
        else
          "#{reason}: #{title}"
        end

      "media_item.removed" ->
        title = event.metadata["title"] || "Unknown"
        "Removed: #{title}"

      "media_item.monitoring_changed" ->
        title = event.metadata["title"] || "Unknown"
        monitored = event.metadata["monitored"]
        action = if monitored, do: "Started monitoring", else: "Stopped monitoring"
        "#{action}: #{title}"

      "download.initiated" ->
        title = event.metadata["title"] || "Unknown"
        "Started download: #{title}"

      "download.completed" ->
        title = event.metadata["title"] || "Unknown"
        "Download completed: #{title}"

      "download.failed" ->
        title = event.metadata["title"] || "Unknown"
        error = event.metadata["error_message"] || "Unknown error"
        selected = event.metadata["selected_release"]

        base = format_search_description("Download failed for", title, event.metadata)

        if selected do
          "#{base}: #{selected} (#{error})"
        else
          "#{base} (#{error})"
        end

      "download.cancelled" ->
        title = event.metadata["title"] || "Unknown"
        "Download cancelled: #{title}"

      "download.paused" ->
        title = event.metadata["title"] || "Unknown"
        "Download paused: #{title}"

      "download.resumed" ->
        title = event.metadata["title"] || "Unknown"
        "Download resumed: #{title}"

      "job.executed" ->
        job_name = event.metadata["job_name"] || "Unknown"
        "Job executed: #{job_name}"

      "job.failed" ->
        job_name = event.metadata["job_name"] || "Unknown"
        error = event.metadata["error_message"] || "Unknown error"
        "Job failed: #{job_name} (#{error})"

      "search.started" ->
        title = event.metadata["title"] || "Unknown"
        format_search_description("Searching for", title, event.metadata)

      "search.completed" ->
        title = event.metadata["title"] || "Unknown"
        selected = event.metadata["selected_release"]

        if selected do
          format_search_description("Found release for", title, event.metadata) <> ": #{selected}"
        else
          format_search_description("Search completed for", title, event.metadata)
        end

      "search.no_results" ->
        title = event.metadata["title"] || "Unknown"
        format_search_description("No results found for", title, event.metadata)

      "search.filtered_out" ->
        title = event.metadata["title"] || "Unknown"
        count = event.metadata["results_count"] || 0
        format_search_description("#{count} results filtered out for", title, event.metadata)

      "search.error" ->
        title = event.metadata["title"] || "Unknown"
        error = event.metadata["error_message"] || "Unknown error"
        format_search_description("Search failed for", title, event.metadata) <> " (#{error})"

      "search.backoff_applied" ->
        title = event.metadata["title"] || "Unknown"
        failure_count = event.metadata["failure_count"] || 1
        reason = format_backoff_reason(event.metadata["reason"])
        next_eligible = format_next_eligible(event.metadata["next_eligible_at"])
        resource_type = determine_backoff_resource_type(event.metadata)

        "#{title}#{format_episode_part(event.metadata)} (#{resource_type}) - #{reason}, attempt ##{failure_count}, next search #{next_eligible}"

      "search.backoff_reset" ->
        title = event.metadata["title"] || "Unknown"
        previous_count = event.metadata["previous_failure_count"] || 0
        resource_type = determine_backoff_resource_type(event.metadata)

        "#{title}#{format_episode_part(event.metadata)} (#{resource_type}) - backoff cleared after #{previous_count} failed attempts"

      _ ->
        event.type
    end
  end

  defp format_search_description(prefix, title, metadata) do
    episode_part =
      case {metadata["season_number"], metadata["episode_number"]} do
        {nil, _} ->
          ""

        {_, nil} ->
          ""

        {s, e} ->
          " S#{String.pad_leading(to_string(s), 2, "0")}E#{String.pad_leading(to_string(e), 2, "0")}"
      end

    "#{prefix}: #{title}#{episode_part}"
  end

  defp format_actor(event) do
    case event.actor_type do
      :user -> "User"
      :system -> "System"
      :job -> format_job_name(event.actor_id)
      nil -> "System"
      _ -> "Unknown"
    end
  end

  defp format_job_name(nil), do: "Job"
  defp format_job_name("movie_search"), do: "Movie Search"
  defp format_job_name("tv_show_search"), do: "TV Search"
  defp format_job_name("episode_search"), do: "Episode Search"
  defp format_job_name("season_search"), do: "Season Search"
  defp format_job_name("metadata_sync"), do: "Metadata Sync"
  defp format_job_name("library_scan"), do: "Library Scan"

  defp format_job_name(job_id) do
    job_id
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp actor_icon(event) do
    case event.actor_type do
      :user -> "hero-user"
      :job -> "hero-cog-6-tooth"
      :system -> "hero-computer-desktop"
      _ -> "hero-computer-desktop"
    end
  end

  defp severity_badge_class(severity) do
    case severity do
      :error -> "badge-error"
      :warning -> "badge-warning"
      :info -> "badge-info"
      _ -> "badge-ghost"
    end
  end

  defp relative_time(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)} minutes ago"
      diff < 86400 -> "#{div(diff, 3600)} hours ago"
      diff < 604_800 -> "#{div(diff, 86400)} days ago"
      true -> Calendar.strftime(datetime, "%b %d, %Y")
    end
  end

  defp event_icon(event) do
    case event.type do
      "media_item.added" -> "hero-plus-circle"
      "media_item.updated" -> "hero-arrow-path"
      "media_item.removed" -> "hero-trash"
      "media_item.monitoring_changed" -> "hero-eye"
      "download.initiated" -> "hero-arrow-down-tray"
      "download.completed" -> "hero-check-circle"
      "download.failed" -> "hero-x-circle"
      "download.cancelled" -> "hero-x-mark"
      "download.paused" -> "hero-pause"
      "download.resumed" -> "hero-play"
      "job.executed" -> "hero-cog-6-tooth"
      "job.failed" -> "hero-exclamation-triangle"
      "search.started" -> "hero-magnifying-glass"
      "search.completed" -> "hero-magnifying-glass"
      "search.no_results" -> "hero-magnifying-glass"
      "search.filtered_out" -> "hero-funnel"
      "search.error" -> "hero-magnifying-glass"
      "search.backoff_applied" -> "hero-clock"
      "search.backoff_reset" -> "hero-arrow-path"
      _ -> "hero-information-circle"
    end
  end

  defp has_search_details?(event) do
    event.category == "search" &&
      (event.metadata["query"] != nil ||
         event.metadata["results_count"] != nil ||
         event.metadata["filter_stats"] != nil ||
         event.metadata["breakdown"] != nil)
  end

  defp has_update_details?(event) do
    event.type == "media_item.updated" &&
      event.metadata["changes"] != nil &&
      event.metadata["changes"] != %{}
  end

  # Formats a short summary of changes for the main event description
  defp format_changes_summary(nil), do: nil
  defp format_changes_summary(changes) when changes == %{}, do: nil

  defp format_changes_summary(changes) do
    parts = []

    # Check for metadata_fields changes (from nested metadata)
    parts =
      case Map.get(changes, "metadata_fields") do
        nil ->
          parts

        fields when is_list(fields) ->
          field_names =
            fields
            |> Enum.take(3)
            |> Enum.map(&format_field_name/1)

          remaining = length(fields) - 3

          if remaining > 0 do
            parts ++ ["#{Enum.join(field_names, ", ")} +#{remaining} more"]
          else
            parts ++ [Enum.join(field_names, ", ")]
          end

        _ ->
          parts
      end

    # Check for simple field changes (title, year, etc.)
    simple_fields = ["title", "original_title", "year"]

    simple_changes =
      changes
      |> Map.take(simple_fields)
      |> Map.keys()

    parts =
      if simple_changes != [] do
        parts ++ simple_changes
      else
        parts
      end

    if parts == [] do
      nil
    else
      Enum.join(parts, ", ")
    end
  end

  defp format_field_name(%{"field" => field}), do: field
  defp format_field_name(field) when is_binary(field), do: field
  defp format_field_name(_), do: "field"

  # Formats the detailed list of changes for the expandable view
  defp format_change_details(changes) when is_nil(changes), do: []
  defp format_change_details(changes) when changes == %{}, do: []

  defp format_change_details(changes) do
    simple_changes =
      changes
      |> Map.take(["title", "original_title", "year"])
      |> Enum.map(fn {field, change} ->
        %{
          field: humanize_field_name(field),
          old: format_change_value(field, change["old"]),
          new: format_change_value(field, change["new"])
        }
      end)

    metadata_changes =
      case Map.get(changes, "metadata_fields") do
        nil ->
          []

        fields when is_list(fields) ->
          Enum.map(fields, fn field_change ->
            %{
              field: humanize_field_name(field_change["field"]),
              old: format_metadata_change_value(field_change["field"], field_change["old"]),
              new: format_metadata_change_value(field_change["field"], field_change["new"])
            }
          end)

        _ ->
          []
      end

    simple_changes ++ metadata_changes
  end

  defp humanize_field_name("overview"), do: "Description"
  defp humanize_field_name("poster"), do: "Poster"
  defp humanize_field_name("backdrop"), do: "Backdrop"
  defp humanize_field_name("tagline"), do: "Tagline"
  defp humanize_field_name("rating"), do: "Rating"
  defp humanize_field_name("runtime"), do: "Runtime"
  defp humanize_field_name("genres"), do: "Genres"
  defp humanize_field_name("cast"), do: "Cast"
  defp humanize_field_name("crew"), do: "Crew"
  defp humanize_field_name("title"), do: "Title"
  defp humanize_field_name("original_title"), do: "Original Title"
  defp humanize_field_name("year"), do: "Year"
  defp humanize_field_name(field), do: Phoenix.Naming.humanize(field)

  defp format_change_value(_field, nil), do: "none"
  defp format_change_value(_field, value), do: to_string(value)

  defp format_metadata_change_value("rating", nil), do: "none"
  defp format_metadata_change_value("rating", value) when is_number(value), do: "#{value}/10"
  defp format_metadata_change_value("genres", nil), do: "none"
  defp format_metadata_change_value("genres", count) when is_integer(count), do: "#{count} genres"
  defp format_metadata_change_value("cast", 0), do: "none"
  defp format_metadata_change_value("cast", count) when is_integer(count), do: "#{count} members"
  defp format_metadata_change_value("crew", 0), do: "none"
  defp format_metadata_change_value("crew", count) when is_integer(count), do: "#{count} members"
  defp format_metadata_change_value(_field, true), do: "added"
  defp format_metadata_change_value(_field, nil), do: "none"
  defp format_metadata_change_value(_field, value), do: to_string(value)

  defp format_filter_stat_label(key) do
    case key do
      "total_results" -> "Total"
      "low_seeders" -> "Low seeders"
      "below_quality_threshold" -> "Below quality"
      "no_valid_season_packs" -> "No season packs"
      # New detailed rejection reasons
      "individual_episode" -> "Episode"
      "missing_season_marker" -> "No season"
      "low_ratio" -> "Low ratio"
      "size_out_of_range" -> "Size"
      "blocked_tag" -> "Blocked"
      _ -> String.replace(key, "_", " ") |> String.capitalize()
    end
  end

  defp format_breakdown_label(key) do
    case key do
      "quality" -> "Quality"
      "seeders" -> "Seeders"
      "size" -> "Size"
      "preferred_tags" -> "Preferred"
      "blocked_tags" -> "Blocked"
      "title_relevance" -> "Title match"
      _ -> String.replace(key, "_", " ") |> String.capitalize()
    end
  end

  defp format_breakdown_value(value) when is_float(value) do
    :erlang.float_to_binary(value, decimals: 1)
  end

  defp format_breakdown_value(value), do: to_string(value)

  # Backoff formatting helpers

  defp format_episode_part(metadata) do
    case {metadata["season_number"], metadata["episode_number"]} do
      {nil, _} ->
        ""

      {s, nil} ->
        " S#{String.pad_leading(to_string(s), 2, "0")}"

      {s, e} ->
        " S#{String.pad_leading(to_string(s), 2, "0")}E#{String.pad_leading(to_string(e), 2, "0")}"
    end
  end

  defp format_backoff_reason("no_results"), do: "no results found"
  defp format_backoff_reason("all_filtered"), do: "all results filtered out"
  defp format_backoff_reason(reason) when is_binary(reason), do: reason
  defp format_backoff_reason(_), do: "search failed"

  defp format_next_eligible(nil), do: "unknown"

  defp format_next_eligible(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} -> format_relative_future_time(dt)
      _ -> iso_string
    end
  end

  defp format_next_eligible(_), do: "unknown"

  defp format_relative_future_time(dt) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(dt, now)

    cond do
      diff_seconds <= 0 -> "now"
      diff_seconds < 60 -> "in #{diff_seconds}s"
      diff_seconds < 3600 -> "in #{div(diff_seconds, 60)}m"
      diff_seconds < 86_400 -> "in #{Float.round(diff_seconds / 3600, 1)}h"
      true -> "in #{div(diff_seconds, 86_400)}d"
    end
  end

  defp determine_backoff_resource_type(metadata) do
    cond do
      metadata["episode_id"] ->
        "episode"

      metadata["season_number"] && !metadata["episode_number"] ->
        "season #{metadata["season_number"]}"

      true ->
        "show"
    end
  end
end
