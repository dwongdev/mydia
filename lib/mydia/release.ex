defmodule Mydia.Release do
  @moduledoc """
  Database backup and migration utilities for release management.

  This module provides functions for:
  - Running database migrations
  - Checking for pending migrations
  - Creating timestamped database backups before migrations
  - Cleaning up old backup files
  """

  require Logger

  @app :mydia
  @max_backups 10

  @doc """
  Runs pending database migrations.

  This is the standard function called by release scripts and entrypoints
  to ensure the database schema is up to date.
  """
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc """
  Rolls back the last migration.
  """
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end

  @doc """
  Creates a database backup if there are pending migrations.

  Returns `{:ok, backup_path}` if a backup was created,
  `{:ok, :no_migrations}` if there are no pending migrations,
  or `{:error, reason}` if the backup failed.
  """
  def backup_before_migrations do
    case pending_migrations?() do
      true ->
        create_backup()

      false ->
        Logger.info("No pending migrations detected, skipping backup")
        {:ok, :no_migrations}
    end
  end

  @doc """
  Checks if there are pending migrations.
  """
  def pending_migrations? do
    repos = Application.get_env(@app, :ecto_repos, [])

    Enum.any?(repos, fn repo ->
      versions = Ecto.Migrator.migrations(repo)

      Enum.any?(versions, fn {status, _version, _name} ->
        status == :down
      end)
    end)
  end

  @doc """
  Creates a timestamped backup of the database file.
  """
  def create_backup do
    with {:ok, db_path} <- get_database_path(),
         :ok <- ensure_database_exists(db_path),
         {:ok, backup_path} <- generate_backup_path(db_path),
         :ok <- copy_database(db_path, backup_path),
         :ok <- verify_backup(backup_path) do
      Logger.info("Created database backup: #{backup_path}")
      cleanup_old_backups(db_path)
      {:ok, backup_path}
    else
      {:error, reason} = error ->
        Logger.error("Failed to create database backup: #{inspect(reason)}")
        error
    end
  end

  # Private functions

  defp get_database_path do
    case Application.get_env(@app, Mydia.Repo)[:database] do
      nil ->
        {:error, :no_database_configured}

      path when is_binary(path) ->
        {:ok, path}

      path ->
        {:error, {:invalid_database_path, path}}
    end
  end

  defp ensure_database_exists(db_path) do
    if File.exists?(db_path) do
      :ok
    else
      {:error, {:database_not_found, db_path}}
    end
  end

  defp generate_backup_path(db_path) do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
    dir = Path.dirname(db_path)
    basename = Path.basename(db_path, ".db")
    backup_name = "#{basename}_backup_#{timestamp}.db"
    backup_path = Path.join(dir, backup_name)

    {:ok, backup_path}
  end

  defp copy_database(source, dest) do
    case File.cp(source, dest) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, {:copy_failed, reason}}
    end
  end

  defp verify_backup(backup_path) do
    case File.stat(backup_path) do
      {:ok, %File.Stat{size: size}} when size > 0 ->
        :ok

      {:ok, %File.Stat{size: 0}} ->
        {:error, :backup_empty}

      {:error, reason} ->
        {:error, {:backup_verify_failed, reason}}
    end
  end

  defp cleanup_old_backups(db_path) do
    # Get the base name of the database file (without extension)
    basename = Path.basename(db_path, ".db")
    dir = Path.dirname(db_path)
    backup_pattern = Path.join(dir, "#{basename}_backup_*.db")

    backup_pattern
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reverse()
    |> Enum.drop(@max_backups)
    |> Enum.each(fn old_backup ->
      case File.rm(old_backup) do
        :ok ->
          Logger.info("Cleaned up old backup: #{old_backup}")

        {:error, reason} ->
          Logger.warning("Failed to remove old backup #{old_backup}: #{inspect(reason)}")
      end
    end)
  end
end
