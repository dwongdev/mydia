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
  Connect to a relay server and request a reservation.
  This allows other peers to connect to us through the relay.
  The address should include the relay's peer ID, e.g., "/ip4/1.2.3.4/tcp/4001/p2p/12D3..."
  """
  def connect_relay(_resource, _relay_addr), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Register under a namespace with the rendezvous point.
  This is used during pairing mode to make the server discoverable.
  """
  def register_namespace(_resource, _namespace, _ttl_secs), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Unregister from a namespace.
  """
  def unregister_namespace(_resource, _namespace), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Get network statistics including routing table size, active registrations, and rendezvous connection status.
  """
  def get_network_stats(_resource), do: :erlang.nif_error(:nif_not_loaded)
end

defmodule Mydia.Libp2p.PairingRequest do
  @moduledoc """
  A pairing request received from a player.
  """
  defstruct [:claim_code, :device_name, :device_type, :device_os]
end

defmodule Mydia.Libp2p.PairingResponse do
  @moduledoc """
  A pairing response to send back to a player.
  """
  defstruct [:success, :media_token, :access_token, :device_token, :error]
end

defmodule Mydia.Libp2p.NetworkStats do
  @moduledoc """
  Network statistics from the libp2p host.
  """
  defstruct [:routing_table_size, :active_registrations, :rendezvous_connected, :kademlia_enabled]

  @type t :: %__MODULE__{
          routing_table_size: non_neg_integer(),
          active_registrations: non_neg_integer(),
          rendezvous_connected: boolean(),
          kademlia_enabled: boolean()
        }
end

defmodule Mydia.Libp2p.DiscoveredPeer do
  @moduledoc """
  A peer discovered via rendezvous.
  """
  defstruct [:peer_id, :addresses]

  @type t :: %__MODULE__{
          peer_id: String.t(),
          addresses: [String.t()]
        }
end
