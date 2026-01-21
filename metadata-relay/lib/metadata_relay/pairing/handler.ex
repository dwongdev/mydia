defmodule MetadataRelay.Pairing.Handler do
  @moduledoc """
  HTTP handler for iroh-based P2P pairing endpoints.

  Implements the simplified pairing API:
  - POST /pairing/claim - Create claim with node_addr, returns claim code
  - GET /pairing/claim/:code - Get node_addr for claim code
  - DELETE /pairing/claim/:code - Delete claim after successful pairing
  """

  alias MetadataRelay.Pairing

  @doc """
  Creates a new claim code for a node_addr.

  ## Request Body
  ```json
  {
    "node_addr": "<EndpointAddr JSON string>"
  }
  ```

  ## Response
  ```json
  {
    "claim_code": "ABC123"
  }
  ```
  """
  def create_claim(params) do
    node_addr = params["node_addr"]

    if is_nil(node_addr) or node_addr == "" do
      {:error, {:validation, "node_addr is required"}}
    else
      case Pairing.create_claim(node_addr) do
        {:ok, claim} ->
          {:ok, %{claim_code: claim.code}}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, {:validation, format_changeset_errors(changeset)}}
      end
    end
  end

  @doc """
  Gets the node_addr for a claim code.

  ## Response
  ```json
  {
    "node_addr": "<EndpointAddr JSON string>"
  }
  ```

  Returns 404 if not found or expired.
  """
  def get_claim(code) do
    case Pairing.get_claim(code) do
      {:ok, node_addr} ->
        {:ok, %{node_addr: node_addr}}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :expired} ->
        # Return generic not_found to prevent enumeration
        {:error, :not_found}
    end
  end

  @doc """
  Deletes a claim code.

  Called after successful pairing.

  ## Response
  204 No Content on success, 404 if not found.
  """
  def delete_claim(code) do
    case Pairing.delete_claim(code) do
      :ok ->
        {:ok, :no_content}

      {:error, :not_found} ->
        # Return success even if not found (idempotent delete)
        {:ok, :no_content}
    end
  end

  # Private helpers

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map(fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
    |> Enum.join("; ")
  end
end
