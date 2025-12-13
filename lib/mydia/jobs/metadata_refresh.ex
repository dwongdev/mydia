defmodule Mydia.Jobs.MetadataRefresh do
  @moduledoc """
  Background job for refreshing media metadata.

  This job:
  - Fetches the latest metadata from providers
  - Updates media items with fresh data
  - For TV shows, updates episode information
  - Can be triggered manually or scheduled

  For scheduled "refresh all" runs, a random delay (0-30 minutes) is applied
  to spread load across self-hosted instances hitting the metadata relay.
  """

  use Oban.Worker,
    queue: :media,
    max_attempts: 3

  require Logger
  alias Mydia.{Media, Metadata}

  # Random delay range for scheduled refresh_all (0-30 minutes in ms)
  @max_startup_delay_ms 30 * 60 * 1000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"media_item_id" => media_item_id} = args}) do
    start_time = System.monotonic_time(:millisecond)
    fetch_episodes = Map.get(args, "fetch_episodes", true)
    config = Metadata.default_relay_config()

    Logger.info("Starting metadata refresh", media_item_id: media_item_id)

    result =
      case Media.get_media_item!(media_item_id) do
        nil ->
          Logger.error("Media item not found", media_item_id: media_item_id)
          {:error, :not_found}

        media_item ->
          refresh_media_item(media_item, config, fetch_episodes)
      end

    duration = System.monotonic_time(:millisecond) - start_time

    case result do
      :ok ->
        Logger.info("Metadata refresh completed",
          duration_ms: duration,
          media_item_id: media_item_id
        )

        :ok

      {:error, reason} ->
        Logger.error("Metadata refresh failed",
          error: inspect(reason),
          duration_ms: duration,
          media_item_id: media_item_id
        )

        {:error, reason}
    end
  rescue
    _e in Ecto.NoResultsError ->
      Logger.error("Media item not found", media_item_id: media_item_id)
      {:error, :not_found}
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"refresh_all" => true} = args}) do
    # Add random delay for scheduled runs to spread load across instances
    # Skip delay for manual triggers (skip_delay: true)
    unless Map.get(args, "skip_delay", false) do
      delay_ms = :rand.uniform(@max_startup_delay_ms)
      delay_minutes = Float.round(delay_ms / 60_000, 1)

      Logger.info("Metadata refresh scheduled, waiting #{delay_minutes} minutes before starting")
      Process.sleep(delay_ms)
    end

    start_time = System.monotonic_time(:millisecond)
    Logger.info("Starting metadata refresh for all media items")

    result = refresh_all_media()
    duration = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, count} ->
        Logger.info("Metadata refresh all completed",
          duration_ms: duration,
          items_processed: count
        )

        :ok
    end
  end

  # Fallback for manual trigger from UI (empty args) - skip delay for immediate execution
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when args == %{} do
    perform(%Oban.Job{args: %{"refresh_all" => true, "skip_delay" => true}})
  end

  ## Private Functions

  defp refresh_media_item(media_item, config, fetch_episodes) do
    # Try to get tmdb_id from media_item or extract from stored metadata
    tmdb_id = get_or_extract_tmdb_id(media_item)
    media_type = parse_media_type(media_item.type)

    # If no TMDB ID, try to recover it via the shared Media function
    {tmdb_id, media_item} =
      if tmdb_id do
        {tmdb_id, media_item}
      else
        Logger.info("No TMDB ID found, attempting to recover by title search",
          media_item_id: media_item.id,
          title: media_item.title
        )

        case Media.recover_tmdb_id_by_title(media_item, media_type) do
          {:ok, found_id, updated_item} ->
            Logger.info("Successfully recovered TMDB ID via title search",
              media_item_id: media_item.id,
              title: media_item.title,
              tmdb_id: found_id
            )

            {found_id, updated_item}

          {:error, reason} ->
            Logger.warning("Failed to recover TMDB ID via title search",
              media_item_id: media_item.id,
              title: media_item.title,
              reason: reason
            )

            {nil, media_item}
        end
      end

    if tmdb_id do
      Logger.info("Refreshing metadata",
        media_item_id: media_item.id,
        title: media_item.title,
        tmdb_id: tmdb_id
      )

      case fetch_updated_metadata(tmdb_id, media_type, config) do
        {:ok, metadata} ->
          attrs = build_update_attrs(metadata, media_type)

          case Media.update_media_item(media_item, attrs, reason: "Metadata refreshed") do
            {:ok, updated_item} ->
              Logger.info("Successfully refreshed metadata",
                media_item_id: updated_item.id,
                title: updated_item.title
              )

              # For TV shows, optionally refresh episodes
              if media_type == :tv_show and fetch_episodes do
                Media.refresh_episodes_for_tv_show(updated_item)
              end

              :ok

            {:error, changeset} ->
              Logger.error("Failed to update media item",
                media_item_id: media_item.id,
                errors: inspect(changeset.errors)
              )

              {:error, :update_failed}
          end

        {:error, reason} ->
          Logger.error("Failed to fetch updated metadata",
            media_item_id: media_item.id,
            tmdb_id: tmdb_id,
            reason: reason
          )

          {:error, reason}
      end
    else
      Logger.warning("Media item has no TMDB ID and could not recover via title search",
        media_item_id: media_item.id
      )

      {:error, :no_tmdb_id}
    end
  end

  defp refresh_all_media do
    media_items = Media.list_media_items(monitored: true)

    Logger.info("Refreshing metadata for #{length(media_items)} media items")

    results =
      Enum.map(media_items, fn media_item ->
        config = Metadata.default_relay_config()
        refresh_media_item(media_item, config, false)
      end)

    successful = Enum.count(results, &(&1 == :ok))
    failed = Enum.count(results, &match?({:error, _}, &1))

    Logger.info("Metadata refresh completed",
      total: length(results),
      successful: successful,
      failed: failed
    )

    {:ok, successful}
  end

  defp parse_media_type("movie"), do: :movie
  defp parse_media_type("tv_show"), do: :tv_show
  defp parse_media_type(_), do: :movie

  defp fetch_updated_metadata(tmdb_id, media_type, config) do
    fetch_opts = [
      media_type: media_type,
      append_to_response: ["credits", "images", "videos", "keywords"]
    ]

    Metadata.fetch_by_id(config, to_string(tmdb_id), fetch_opts)
  end

  defp build_update_attrs(metadata, _media_type) do
    %{
      title: metadata.title,
      original_title: metadata.original_title,
      year: extract_year(metadata),
      tmdb_id: metadata.id,
      imdb_id: metadata.imdb_id,
      metadata: metadata
    }
  end

  defp get_or_extract_tmdb_id(media_item) do
    cond do
      # If tmdb_id is already set, use it
      media_item.tmdb_id ->
        media_item.tmdb_id

      # Try to extract from metadata["id"] (new format after fix - string key)
      media_item.metadata && media_item.metadata["id"] ->
        case media_item.metadata["id"] do
          id when is_integer(id) ->
            id

          id when is_binary(id) ->
            case Integer.parse(id) do
              {parsed_id, ""} -> parsed_id
              _ -> nil
            end

          _ ->
            nil
        end

      # Try to extract from metadata["provider_id"] (old format - string key)
      media_item.metadata && media_item.metadata["provider_id"] ->
        case Integer.parse(media_item.metadata["provider_id"]) do
          {id, ""} -> id
          _ -> nil
        end

      # No tmdb_id available
      true ->
        nil
    end
  end

  defp extract_year(metadata) do
    cond do
      metadata.release_date ->
        metadata.release_date.year

      metadata.first_air_date ->
        metadata.first_air_date.year

      true ->
        nil
    end
  end
end
