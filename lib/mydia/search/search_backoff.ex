defmodule Mydia.Search.SearchBackoff do
  @moduledoc """
  Schema for tracking search backoff state.

  When searches fail or return no usable results, we apply exponential backoff
  to avoid hammering indexers with repeated failing queries. This tracks the
  backoff state per resource (movie, tv_show, season, episode).

  ## Backoff Schedule

  15min → 30min → 1hr → 4hr → 12hr → 24hr → 3 days → 7 days (cap)

  ## Resource Types

  - `"movie"` - Per-movie backoff, resource_id = media_item.id
  - `"tv_show"` - Per-show backoff, resource_id = media_item.id
  - `"season"` - Per-season backoff, resource_id = media_item.id, season_number set
  - `"episode"` - Per-episode backoff, resource_id = episode.id
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "search_backoffs" do
    field :resource_type, :string
    field :resource_id, :binary_id
    field :season_number, :integer
    field :failure_count, :integer, default: 0
    field :last_failure_reason, :string
    field :next_eligible_at, :utc_datetime
    field :first_failed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(backoff, attrs) do
    backoff
    |> cast(attrs, [
      :resource_type,
      :resource_id,
      :season_number,
      :failure_count,
      :last_failure_reason,
      :next_eligible_at,
      :first_failed_at
    ])
    |> validate_required([:resource_type, :resource_id])
    |> validate_inclusion(:resource_type, ["movie", "tv_show", "season", "episode"])
  end
end
