defmodule Mydia.Libp2p do
  @moduledoc """
  NIF bindings for Libp2p.
  """
  use Rustler, otp_app: :mydia, crate: "mydia_libp2p"

  # When your NIF is loaded, it will override this function.
  def start_host(), do: :erlang.nif_error(:nif_not_loaded)

  def listen(_resource, _addr), do: :erlang.nif_error(:nif_not_loaded)

  def dial(_resource, _addr), do: :erlang.nif_error(:nif_not_loaded)

  def start_listening(_resource, _pid), do: :erlang.nif_error(:nif_not_loaded)

  def send_response(_resource, _request_id, _response), do: :erlang.nif_error(:nif_not_loaded)

  def stream_file(_resource, _stream_id, _file_path), do: :erlang.nif_error(:nif_not_loaded)
end

defmodule Mydia.Libp2p.PairingRequest do
  defstruct [:claim_code, :device_name, :device_type, :device_os]
end

defmodule Mydia.Libp2p.PairingResponse do
  defstruct [:success, :media_token, :access_token, :device_token, :error]
end
