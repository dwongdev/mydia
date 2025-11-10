defmodule MydiaWeb.HealthController do
  use MydiaWeb, :controller
  alias Mydia.System

  @doc """
  Health check endpoint for Docker health checks and load balancers.
  Returns 200 OK with basic system status.
  """
  def check(conn, _params) do
    response = %{
      status: "ok",
      service: "mydia",
      version: System.app_version(),
      dev_mode: System.dev_mode?(),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    json(conn, response)
  end
end
