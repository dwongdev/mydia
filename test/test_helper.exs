# Limit concurrent test execution for SQLite compatibility
# SQLite doesn't handle high concurrency well, even with WAL mode
# Using 1 concurrent case to avoid "Database busy" errors with SQLite
# Exclude external integration tests by default (require external services)
# Exclude feature tests by default (require chromedriver)
# Exclude relay tests by default (require connected relay service)
# Run specific tests explicitly with: mix test --include <tag>
ExUnit.start(max_cases: 1, exclude: [:external, :feature, :requires_relay])
Ecto.Adapters.SQL.Sandbox.mode(Mydia.Repo, :manual)

# Configure ExMachina
{:ok, _} = Application.ensure_all_started(:ex_machina)

# Start Wallaby for feature tests only if chromedriver is available
# Check if we can find chromedriver in PATH
chromedriver_available =
  case System.find_executable("chromedriver") do
    nil ->
      # Also check custom path from config
      case Application.get_env(:wallaby, :chromedriver)[:path] do
        nil -> false
        path -> File.exists?(path)
      end

    _path ->
      true
  end

if chromedriver_available do
  {:ok, _} = Application.ensure_all_started(:wallaby)
else
  IO.puts("""
  \n⚠️  chromedriver not found - Wallaby feature tests will be skipped.
  To run feature tests, install chromedriver:
    - macOS: brew install chromedriver
    - Ubuntu: apt-get install chromium-chromedriver
    - Or set config :wallaby, :chromedriver, path: "/path/to/chromedriver"
  """)
end
