defmodule MetadataRelay.Relay.Namespace do
  @moduledoc """
  Handles namespace derivation for libp2p rendezvous.

  We use a time-based pepper rotation scheme to derive the rendezvous namespace
  from the short claim code. This prevents attackers from brute-forcing the
  namespace to find active servers, since the short claim code space is small.

  Rotation:
  - Epoch: 1 hour
  - We accept tokens from current and previous epoch (grace window)
  """

  require Logger

  @prefix "mydia-claim:"

  @doc """
  Derives the full rendezvous namespace for a claim code.

  Returns "mydia-claim:<base32-token>"
  """
  def derive_namespace(claim_code) do
    token = derive_token(claim_code, current_epoch())
    "#{@prefix}#{token}"
  end

  @doc """
  Derives the raw token for a claim code (for testing/validation).
  """
  def derive_token(claim_code, epoch \\ nil) do
    epoch = epoch || current_epoch()
    master_pepper = Application.fetch_env!(:metadata_relay, :rendezvous_master_pepper)

    # Derive effective pepper for this epoch
    effective_pepper = :crypto.mac(:hmac, :sha256, master_pepper, to_string(epoch))

    # Derive token from code using effective pepper
    :crypto.mac(:hmac, :sha256, effective_pepper, claim_code)
    |> Base.encode32(padding: false, case: :lower)
  end

  @doc """
  Checks if a namespace string is valid for a given claim code.

  Accepts namespaces derived from current OR previous epoch.
  """
  def valid_namespace?(claim_code, namespace) do
    case String.split(namespace, ":", parts: 2) do
      ["mydia-claim", token] ->
        epoch = current_epoch()

        token == derive_token(claim_code, epoch) or
          token == derive_token(claim_code, epoch - 1)

      _ ->
        false
    end
  end

  defp current_epoch do
    System.os_time(:second) |> div(3600)
  end
end
