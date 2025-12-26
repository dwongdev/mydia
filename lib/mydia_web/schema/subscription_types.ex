defmodule MydiaWeb.Schema.SubscriptionTypes do
  @moduledoc """
  GraphQL subscription type definitions for real-time updates.
  """

  use Absinthe.Schema.Notation

  object :playback_subscriptions do
    @desc "Subscribe to playback progress updates for a specific content item"
    field :progress_updated, :progress do
      arg(:node_id, non_null(:id))

      config(fn args, _info ->
        {:ok, topic: args.node_id}
      end)
    end
  end
end
