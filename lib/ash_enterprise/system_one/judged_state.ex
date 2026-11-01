defmodule AshEnterprise.SystemOne.JudgedState do
  @moduledoc """
  The text a model judged, sealed on its judgment so that a person deciding
  a review-banded answer can read what the model read (S1-98).

  ## What is sealed

  The judge sends the model the question's projection of its input, never
  the raw input (`AshJudgments.Registry.Judge`), and records that state's
  digest as the observation's `state_digest`. This module seals that same
  state into the observation's `state_ciphertext`: a string state as it is,
  any other state as its canonical JSON (`AshJudgments.Registry.Canonical`),
  the encoding the digest is taken over. A state whose digest differs from
  the recorded `state_digest` is never sealed: it is not the text that was
  judged.

  ## How it reaches the ledger

  A caller that runs a judge action carries the state it projected in the
  judge context (`AshEnterprise.SystemOne.judge_context/1`, the
  `judged_state:` option). The package's recorder passes that context to the
  ledger's `:record` create, where `AshEnterprise.SystemOne.Changes.SealJudgedState`
  seals it. That change is the one seam: every observation this host records
  goes through it, whichever path recorded it.

  ## The erasure scope (ADR 0024)

  The state is sealed under one erasure scope, through
  `AshEnterprise.Erasure.Keyring.seal/2`; this module never holds a key.

    * **The subject's own scope**, when the judged record is sealed under one
      (it has an `erasure_scope_id`). The text was read from that record, so
      shredding the record's scope shreds the text too.
    * **Otherwise the tenant's judged-text scope**: `data_subject`, ref
      `judged_state:<organization id>`, opened by the system actor the first
      time it is needed. A code unit, a match candidate or a licence has no
      scope of its own. This follows the rule ADR 0055 set for invocation
      payloads: the subject's scope when it has one, otherwise a
      `data_subject` scope with an opaque ref.

  A shredded scope is never reopened, so a judgment recorded after its
  scope was shredded is recorded without its text.
  """

  alias AshEnterprise.Erasure
  alias AshEnterprise.Erasure.Keyring
  alias AshEnterprise.Platform.SystemActor
  alias AshJudgments.Registry.Canonical

  @label "Judged text"

  @doc """
  The state a question's judge sends for `input`, the judge action's input:
  the registry's projection dispatch (`AshJudgments.Registry.Judge`),
  repeated here so the state is the one the judge digests.
  """
  @spec project(map(), Ash.ActionInput.t()) :: term()
  def project(%{state_projection: nil}, input) do
    Map.new(input.arguments, fn {k, v} -> {Atom.to_string(k), v} end)
  end

  def project(%{state_projection: projection}, input) when is_function(projection, 2),
    do: projection.(input, input.context)

  def project(%{state_projection: {m, f, a}}, input),
    do: apply(m, f, [input, input.context | a])

  def project(%{state_projection: m}, input) when is_atom(m), do: m.project(input, input.context)

  @doc "The digest the judge records as `state_digest` for `state`."
  @spec digest(term()) :: String.t()
  def digest(state), do: state |> Canonical.encode() |> Canonical.digest()

  @doc "The text sealed for `state`: a string as it is, anything else as canonical JSON."
  @spec text(term()) :: String.t()
  def text(state) when is_binary(state), do: state
  def text(state), do: Canonical.encode(state)

  @doc """
  Seals `state` for an observation that recorded `state_digest`, in
  `tenant`, under `scope_id` (the subject's own scope) or, when that is
  nil, the tenant's judged-text scope.

  `{:error, :changed}` when the state's digest is not the recorded one;
  `{:error, :shredded}` when the scope is shredded.
  """
  @spec seal(term(), String.t(), term(), Ash.UUID.t() | nil) ::
          {:ok, binary()} | {:error, :changed | :shredded | :unknown_scope | :no_tenant | term()}
  def seal(state, state_digest, tenant, scope_id \\ nil) do
    if digest(state) == state_digest do
      with {:ok, scope_id} <- scope(tenant, scope_id) do
        Keyring.seal(scope_id, text(state))
      end
    else
      {:error, :changed}
    end
  end

  @doc "The ref of a tenant's judged-text scope."
  @spec scope_ref(term()) :: String.t()
  def scope_ref(tenant), do: "judged_state:#{tenant}"

  defp scope(_tenant, scope_id) when is_binary(scope_id), do: {:ok, scope_id}
  defp scope(nil, nil), do: {:error, :no_tenant}

  defp scope(tenant, nil) do
    case Erasure.ensure_scope(:data_subject, scope_ref(tenant), %{label: @label},
           actor: SystemActor.system()
         ) do
      {:ok, %{status: :active, id: id}} -> {:ok, id}
      {:ok, _shredded} -> {:error, :shredded}
      {:error, error} -> {:error, error}
    end
  end
end
