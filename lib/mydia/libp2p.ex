defmodule Mydia.Libp2p do
  @moduledoc """
  NIF bindings for Libp2p.
  """
  use Rustler, otp_app: :mydia, crate: "mydia_libp2p"

  # When your NIF is loaded, it will override this function.
  def start_host(), do: :erlang.nif_error(:nif_not_loaded)

  def listen(_resource, _addr), do: :erlang.nif_error(:nif_not_loaded)
end
