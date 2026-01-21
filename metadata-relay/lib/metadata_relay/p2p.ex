defmodule MetadataRelay.P2p do
  @moduledoc """
  NIF bindings for iroh-based P2P.

  Note: With the migration to iroh, the metadata-relay no longer needs to run
  its own relay server. iroh uses its own public relay infrastructure.
  This module is kept for backwards compatibility.
  """
  use Rustler, otp_app: :metadata_relay, crate: "metadata_relay_p2p"

  @doc """
  Start the P2P host.
  Returns `{:ok, {resource, node_id}}` or `{resource, node_id}`.
  """
  def start_relay(), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Get the node address as a JSON string.
  Returns a String (JSON-serialized EndpointAddr).
  """
  def get_node_addr(_resource), do: :erlang.nif_error(:nif_not_loaded)
end
