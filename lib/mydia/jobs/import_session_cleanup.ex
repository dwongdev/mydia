defmodule Mydia.Jobs.ImportSessionCleanup do
  @moduledoc """
  Background job for cleaning up old import sessions.

  Runs daily to:
  - Delete expired import sessions (past their expiration date)
  - Delete completed import sessions older than 7 days

  This prevents database bloat from abandoned or completed import sessions.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3

  require Logger
  alias Mydia.Library

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("Starting import session cleanup job")

    # Clean up expired sessions
    {:ok, expired_count} = Library.delete_expired_import_sessions()
    Logger.info("Deleted expired import sessions", count: expired_count)

    # Clean up old completed sessions (older than 7 days)
    {:ok, completed_count} = Library.delete_old_completed_sessions(7)
    Logger.info("Deleted old completed import sessions", count: completed_count)

    Logger.info("Import session cleanup completed",
      expired_deleted: expired_count,
      completed_deleted: completed_count
    )

    :ok
  end
end
