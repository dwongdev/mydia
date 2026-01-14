defmodule MetadataRelay.P2p do
  @moduledoc """
  NIF bindings for Libp2p Relay.
  """
  use Rustler, otp_app: :metadata_relay, crate: "metadata_relay_p2p"

  def start_relay(), do: :erlang.nif_error(:nif_not_loaded)

  def listen(_resource, _addr), do: :erlang.nif_error(:nif_not_loaded)

  def add_external_address(_resource, _addr), do: :erlang.nif_error(:nif_not_loaded)
end
