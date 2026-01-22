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

    with :ok <- validate_node_addr(node_addr),
         {:ok, claim} <- Pairing.create_claim(node_addr) do
      {:ok, %{claim_code: claim.code}}
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
    end
  end

  @doc """
  Deletes a claim code.

  Called after successful pairing.

  ## Response
  204 No Content on success.
  """
  def delete_claim(code) do
    Pairing.delete_claim(code)
    {:ok, :no_content}
  end

  # Private helpers

  defp validate_node_addr(nil), do: {:error, {:validation, "node_addr is required"}}
  defp validate_node_addr(""), do: {:error, {:validation, "node_addr is required"}}

  defp validate_node_addr(node_addr) when is_binary(node_addr) do
    case Jason.decode(node_addr) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, {:validation, "node_addr must be valid JSON"}}
    end
  end

  defp validate_node_addr(_), do: {:error, {:validation, "node_addr must be a string"}}
end
