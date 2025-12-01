defmodule MydiaWeb.Plugs.RuntimeUeberauth do
  @moduledoc """
  A wrapper plug for Ueberauth that initializes routes at runtime instead of compile time.

  This solves the issue where `plug Ueberauth` reads its configuration at compile time,
  which doesn't work with runtime.exs configuration in releases. The OIDC providers
  are configured via environment variables in runtime.exs, but the standard Ueberauth
  plug caches its routes when the controller module is compiled.

  This plug calls `Ueberauth.init/1` at runtime (during each request), ensuring it
  always has the latest configuration from runtime.exs.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    # Initialize Ueberauth routes at runtime, reading current config
    routes = Ueberauth.init([])

    # Call Ueberauth with the runtime-initialized routes
    Ueberauth.call(conn, routes)
  end
end
