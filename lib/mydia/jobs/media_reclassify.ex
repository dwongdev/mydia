defmodule Mydia.Jobs.MediaReclassify do
  @moduledoc """
  Background job for reclassifying media items in a library.

  This job re-runs the category classifier on all media items in a library path,
  updating their categories based on current metadata.
  """

  use Oban.Worker,
    queue: :media,
    max_attempts: 1

  require Logger
  alias Mydia.{Media, Library, Settings}

  @pubsub Mydia.PubSub
  @topic "library_scanner"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"library_path_id" => library_path_id}}) do
    start_time = System.monotonic_time(:millisecond)

    Logger.info("Starting media reclassification job",
      library_path_id: library_path_id
    )

    broadcast_started(library_path_id)

    library_path = Settings.get_library_path!(library_path_id)
    media_ids = Library.list_media_ids_in_library_path(library_path)

    {:ok, summary} = Media.reclassify_media_items(media_ids)

    duration = System.monotonic_time(:millisecond) - start_time

    Logger.info("Media reclassification completed",
      library_path_id: library_path_id,
      total: summary.total,
      updated: summary.updated,
      skipped: summary.skipped,
      unchanged: summary.unchanged,
      duration_ms: duration
    )

    broadcast_completed(library_path_id, summary)
    :ok
  end

  @doc """
  Enqueues a media reclassification job for a library path.
  """
  def enqueue(library_path_id) do
    %{library_path_id: library_path_id}
    |> __MODULE__.new()
    |> Oban.insert()
  end

  defp broadcast_started(library_path_id) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {
      :media_reclassify_started,
      %{library_path_id: library_path_id}
    })
  end

  defp broadcast_completed(library_path_id, summary) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {
      :media_reclassify_completed,
      %{
        library_path_id: library_path_id,
        total: summary.total,
        updated: summary.updated,
        skipped: summary.skipped,
        unchanged: summary.unchanged
      }
    })
  end
end
