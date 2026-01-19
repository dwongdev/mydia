defmodule Mix.Tasks.Mydia.Graphql do
  @moduledoc """
  GraphQL schema management and validation tools.

  The Flutter client uses a symlink to the server's exported schema at
  `priv/graphql/schema.graphql`. This ensures both sides always use the
  same schema definition.

  ## Commands

  ### Export schema

      mix mydia.graphql export

  Exports the current server schema to priv/graphql/schema.graphql.
  The Flutter client's symlink will automatically use this updated schema.

  ### Validate client operations

      mix mydia.graphql validate

  Validates all Flutter client GraphQL operations (.graphql files)
  against the current server schema using graphql-inspector.

  Requires: npx (Node.js)

  ### Full check (recommended for CI)

      mix mydia.graphql check

  Exports schema and validates all client operations.

  ## Examples

      mix mydia.graphql export
      mix mydia.graphql validate
      mix mydia.graphql check

  """
  use Mix.Task

  @shortdoc "GraphQL schema management and validation"

  @server_schema_path "priv/graphql/schema.graphql"
  @client_graphql_dir "player/lib/graphql"

  @impl Mix.Task
  def run(args) do
    case args do
      ["export" | _rest] -> export_schema()
      ["validate" | _rest] -> validate_operations()
      ["check" | _rest] -> full_check()
      _ -> show_usage()
    end
  end

  defp export_schema do
    Mix.shell().info("Exporting GraphQL schema...")

    # Ensure directory exists
    File.mkdir_p!(Path.dirname(@server_schema_path))

    Mix.Task.run("absinthe.schema.sdl", ["--schema", "MydiaWeb.Schema", @server_schema_path])

    if File.exists?(@server_schema_path) do
      Mix.shell().info("✓ Schema exported to #{@server_schema_path}")
      Mix.shell().info("  (Flutter client symlink will use this automatically)")
      :ok
    else
      Mix.shell().error("✗ Failed to export schema")
      exit({:shutdown, 1})
    end
  end

  defp validate_operations do
    Mix.shell().info("Validating Flutter client GraphQL operations...")
    Mix.shell().info("")

    # Ensure schema is up to date
    export_schema()
    Mix.shell().info("")

    # Check if npx is available
    case System.find_executable("npx") do
      nil ->
        Mix.shell().error("✗ npx not found. Please install Node.js")
        exit({:shutdown, 1})

      _npx ->
        run_graphql_inspector()
    end
  end

  defp run_graphql_inspector do
    # Count operation files
    operation_files =
      Path.wildcard("#{@client_graphql_dir}/**/*.graphql")
      |> Enum.reject(&String.ends_with?(&1, "schema.graphql"))

    Mix.shell().info("Found #{length(operation_files)} operation files to validate")
    Mix.shell().info("")

    # Run graphql-inspector validate
    args = [
      "--yes",
      "@graphql-inspector/cli",
      "validate",
      "#{@client_graphql_dir}/**/*.graphql",
      @server_schema_path,
      "--noStrictFragments"
    ]

    case System.cmd("npx", args, stderr_to_stdout: true) do
      {output, 0} ->
        Mix.shell().info(output)
        Mix.shell().info("")
        Mix.shell().info("✓ All operations are valid")
        :ok

      {output, _exit_code} ->
        Mix.shell().info(output)
        Mix.shell().info("")
        Mix.shell().error("✗ Validation failed - see errors above")
        exit({:shutdown, 1})
    end
  end

  defp full_check do
    Mix.shell().info("=" |> String.duplicate(60))
    Mix.shell().info("GraphQL Full Validation Check")
    Mix.shell().info("=" |> String.duplicate(60))
    Mix.shell().info("")

    validate_operations()

    Mix.shell().info("")
    Mix.shell().info("=" |> String.duplicate(60))
    Mix.shell().info("✓ GraphQL check complete")
    Mix.shell().info("=" |> String.duplicate(60))
  end

  defp show_usage do
    Mix.shell().info(@moduledoc)
  end
end
