defmodule MydiaWeb.UserSocket do
  use Phoenix.Socket

  # Define the channel for device connections
  # channel "device:*", MydiaWeb.DeviceChannel

  @impl true
  def connect(_params, socket, _connect_info) do
    # For device reconnection, we don't authenticate in connect/3
    # Authentication happens during the Noise handshake in the channel
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
