defmodule MetadataRelay.Metrics do
  @moduledoc """
  Simple metrics collector for Prometheus.
  Stores counters in ETS for high performance.
  """

  use GenServer

  @table :metrics_counters

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    # Create ETS table if it doesn't exist
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, {:write_concurrency, true}])
    end

    {:ok, %{}}
  end

  def inc(name, labels \\ []) do
    key = {name, Enum.sort(labels)}

    try do
      :ets.update_counter(@table, key, {2, 1}, {key, 0})
    rescue
      ArgumentError ->
        # Table might not exist yet if called too early or during tests
        :ok
    end
  end

  def format do
    :ets.tab2list(@table)
    |> Enum.group_by(fn {{name, _labels}, _val} -> name end)
    |> Enum.map(fn {name, entries} ->
      type_line = "# TYPE #{name} counter"

      lines =
        Enum.map(entries, fn {{_, labels}, value} ->
          label_str =
            labels
            |> Enum.map(fn {k, v} -> "#{k}=\"#{v}\"" end)
            |> Enum.join(",")

          if label_str == "" do
            "#{name} #{value}"
          else
            "#{name}{#{label_str}} #{value}"
          end
        end)

      [type_line | lines] |> Enum.join("\n")
    end)
    |> Enum.join("\n\n")
  end
end
