defmodule MetadataRelay.PairingStore do
  @moduledoc """
  Long-lived owner process for pairing ETS fallback storage.
  """

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ok = MetadataRelay.Pairing.init_ets_table()
    {:ok, %{}}
  end
end
