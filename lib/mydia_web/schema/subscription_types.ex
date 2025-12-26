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

  object :device_subscriptions do
    @desc "Subscribe to device status changes for a user"
    field :device_status_changed, :device_status_event do
      arg(:user_id, non_null(:id))

      config(fn args, _info ->
        {:ok, topic: "device_status:#{args.user_id}"}
      end)
    end
  end

  @desc "Device status change event"
  object :device_status_event do
    field :device, non_null(:device), description: "The device that changed status"
    field :event, non_null(:device_event_type), description: "The type of status change"
  end

  @desc "Remote device information"
  object :device do
    field :id, non_null(:id), description: "Device ID"
    field :device_name, non_null(:string), description: "User-friendly device name"
    field :platform, non_null(:string), description: "Platform (ios, android, web)"
    field :last_seen_at, :datetime, description: "Last time device connected"
    field :revoked_at, :datetime, description: "Revocation timestamp if revoked"
    field :inserted_at, non_null(:datetime), description: "Initial pairing timestamp"
  end

  @desc "Type of device status event"
  enum :device_event_type do
    value(:connected, description: "Device connected")
    value(:disconnected, description: "Device disconnected (no heartbeat)")
    value(:revoked, description: "Device was revoked by user")
    value(:deleted, description: "Device was deleted")
  end
end
