defmodule MydiaWeb.ActivityLive.Index do
  use MydiaWeb, :live_view
  alias Mydia.Events
  alias Phoenix.PubSub

  @impl true
  def mount(_params, _session, socket) do
    socket =
      if connected?(socket) do
        # Subscribe to events for real-time updates
        PubSub.subscribe(Mydia.PubSub, "events:all")

        socket
        |> assign(:category_filter, "all")
        |> assign(:events_empty?, false)
        |> load_events()
      else
        socket
        |> assign(:category_filter, "all")
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
     |> load_events()}
  end

  @impl true
  def handle_info({:event_created, event}, socket) do
    filter = socket.assigns.category_filter

    # Only add event if it matches current filter
    should_add =
      case filter do
        "all" -> true
        "errors" -> event.severity == :error
        category -> event.category == category
      end

    socket =
      if should_add do
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
    filter = socket.assigns.category_filter

    filter_opts =
      case filter do
        "all" -> []
        "errors" -> [severity: :error]
        category -> [category: category]
      end

    events = Events.list_events(filter_opts ++ [limit: 50])

    socket
    |> assign(:events_empty?, events == [])
    |> stream(:events, events, reset: true)
  end

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
        "#{reason}: #{title}"

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
      :job -> event.actor_id || "Job"
      nil -> "System"
      _ -> "Unknown"
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

  defp category_name(category) do
    case category do
      "media" -> "Media"
      "downloads" -> "Downloads"
      "library" -> "Library"
      "system" -> "System"
      "auth" -> "Authentication"
      "search" -> "Search"
      "errors" -> "Error"
      "all" -> "All"
      _ -> String.capitalize(category)
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
