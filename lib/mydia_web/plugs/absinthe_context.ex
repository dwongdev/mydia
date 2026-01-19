defmodule MydiaWeb.Plugs.AbsintheContext do
  @moduledoc """
  Builds the Absinthe context for GraphQL requests.

  Extracts the current user from Guardian and adds it to the Absinthe context.
  This allows resolvers to access the authenticated user via `context[:current_user]`.
  """
  @behaviour Plug

  alias Mydia.Auth.Guardian

  def init(opts), do: opts

  def call(conn, _opts) do
    context = build_context(conn)
    Absinthe.Plug.put_options(conn, context: context)
  end

  defp build_context(conn) do
    case Guardian.Plug.current_resource(conn) do
      nil -> %{}
      user -> %{current_user: user}
    end
  end
end
