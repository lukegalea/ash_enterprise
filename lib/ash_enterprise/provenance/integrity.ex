defmodule AshEnterprise.Provenance.Integrity do
  @moduledoc """
  The integrity of an audit step (ADR 0078, section 7): whether the record it
  rests on is anchored in a verified audit chain, read from the verification
  the chain verifier records each day — never computed by walking a chain
  inside a read.

  The one read this makes is machinery: `AshCompliance.Ownership.Evidence.for_control/3`
  reads evidence with its default `authorize?: false`, because evidence reads
  are trusted machinery, like the sweep that collects it — and the chain
  verifiers read as machinery, with no actor (ADR 0078). This module is where
  that default is allowed, and nowhere else in the explanation is. What it
  keeps of the artifact is the status and its `verified_at`, and the findings'
  sequence and problem, which decide a row's status and are never shown:
  no counts, no finding positions, no ids reach an answer.

  The verification is read at most once per explain call, memoized in the
  walk's context cache under the tenant.
  """

  alias AshCompliance.Ownership.Evidence
  alias AshEnterprise.Audit.ChainVerifyWorker

  # The criterion the daily chain verification evidences (ADR 0078, section 7;
  # `ChainVerifyWorker.evidence_controls/0`).
  @control "CC4.1"

  # The verifier's vocabulary, unchanged, from its JSON spelling to atoms.
  # A fixed map: never `String.to_atom/1` on recorded content.
  @problems %{
    "altered" => :altered,
    "broken_link" => :broken_link,
    "unchained" => :unchained
  }

  @doc """
  The tenant's newest recorded audit-chain verification — `%{verified_at:,
  findings:}` — or nil when none is recorded. Returns it beside the cache to
  store: `{verification, new_cache}`.
  """
  @spec verification(AshEnterprise.Provenance.Explainer.ctx()) :: {map() | nil, map()}
  def verification(ctx) do
    key = {:audit_chain_verification, ctx.tenant}

    case Map.fetch(ctx.cache, key) do
      {:ok, verification} ->
        {verification, ctx.cache}

      :error ->
        verification = latest_verification(ctx.tenant)
        {verification, Map.put(ctx.cache, key, verification)}
    end
  end

  @doc """
  The integrity of one audit event under a recorded verification, or nil
  ("not checked"): an event with no hash is `:unchained`; one the
  verification predates was never checked; a finding at its sequence is that
  finding's problem; a finding at a lower sequence is a broken link it
  inherits; anything else the verification covered and found nothing at or
  before is `:verified`.
  """
  @spec step_integrity(Ash.Resource.record(), map() | nil) :: AshProvenance.Integrity.t() | nil
  def step_integrity(_event, nil), do: nil

  def step_integrity(event, verification) do
    status =
      cond do
        is_nil(event.hash) ->
          :unchained

        DateTime.compare(verification.verified_at, event.occurred_at) == :lt ->
          nil

        finding = Enum.find(verification.findings, &(&1.sequence == event.sequence)) ->
          finding.problem

        Enum.any?(verification.findings, &(&1.sequence < event.sequence)) ->
          :broken_link

        true ->
          :verified
      end

    status &&
      AshProvenance.Integrity.new!(
        anchor: :audit_chain,
        status: status,
        verified_at: verification.verified_at
      )
  end

  # -- The one machinery read ----------------------------------------------

  defp latest_verification(nil), do: nil

  defp latest_verification(tenant) do
    case Evidence.for_control(tenant, @control) do
      {:ok, artifacts} ->
        # `for_control` orders collected-first for a stable hot+archive merge;
        # the recorded verification is the newest of ours, whatever order it
        # came back in.
        artifacts
        |> Enum.filter(&chain_verification?/1)
        |> Enum.sort_by(& &1.collected_at, {:desc, DateTime})
        |> List.first()
        |> decode()

      {:error, _unreadable} ->
        nil
    end
  end

  defp chain_verification?(artifact) do
    artifact.collector == ChainVerifyWorker.producer() and
      artifact.subject_type == ChainVerifyWorker.subject_type()
  end

  # Only verified_at and the findings' sequence and problem survive the decode:
  # nothing else from the artifact can reach an answer.
  defp decode(nil), do: nil

  defp decode(artifact) do
    with {:ok, %{"verified_at" => at, "findings" => findings}} <-
           Jason.decode(artifact.content || ""),
         {:ok, verified_at, _offset} <- DateTime.from_iso8601(at) do
      %{
        verified_at: verified_at,
        findings: Enum.flat_map(findings, &finding/1)
      }
    else
      _undecodable_or_unreadable -> nil
    end
  end

  defp finding(%{"sequence" => sequence, "problem" => problem}) when is_integer(sequence) do
    case Map.fetch(@problems, problem) do
      {:ok, problem} -> [%{sequence: sequence, problem: problem}]
      :error -> []
    end
  end

  defp finding(_unrecognised), do: []
end
