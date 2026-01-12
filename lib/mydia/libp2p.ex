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

  def respond_with_file_chunk(_resource, _request_id, _file_path, _offset, _length),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Add a bootstrap peer and initiate DHT bootstrap.
  The address should include the peer ID, e.g., "/ip4/1.2.3.4/tcp/4001/p2p/12D3..."
  """
  def bootstrap(_resource, _addr), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Provide a claim code on the DHT, announcing this peer as the provider.
  Call this when a new claim code is generated.
  """
  def provide_claim_code(_resource, _claim_code), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Get DHT statistics including routing table size, provided keys count, and bootstrap status.
  """
  def get_dht_stats(_resource), do: :erlang.nif_error(:nif_not_loaded)
end

defmodule Mydia.Libp2p.PairingRequest do
  defstruct [:claim_code, :device_name, :device_type, :device_os]
end

defmodule Mydia.Libp2p.PairingResponse do
  defstruct [:success, :media_token, :access_token, :device_token, :error]
end

defmodule Mydia.Libp2p.DhtStats do
  @moduledoc """
  DHT statistics from the libp2p host.
  """
  defstruct [:routing_table_size, :provided_keys_count, :bootstrap_complete]

  @type t :: %__MODULE__{
          routing_table_size: non_neg_integer(),
          provided_keys_count: non_neg_integer(),
          bootstrap_complete: boolean()
        }
end
