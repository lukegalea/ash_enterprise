defmodule AshEnterprise.SystemOne.Changes.SealJudgedState do
  @moduledoc """
  Seals the state a model judged into the observation's `state_ciphertext`
  as the ledger records it (S1-98, `AshEnterprise.SystemOne.JudgedState`).

  The state rides the judge context the recorder passes to the `:record`
  create: `context.judgments.judged_state`, and the subject's own erasure
  scope as `context.judgments.judged_state_scope_id` when it has one. Both
  are put there by `AshEnterprise.SystemOne.judge_context/1`.

  The observation is recorded whether or not its text can be sealed: a
  record the judge must write is never refused because of its text. So the
  text is left out, and the reason logged by observation id alone, when:

    * the carried state's digest is not the recorded `state_digest` (it is
      not the text that was judged);
    * its erasure scope is shredded, or cannot be opened.

  A row that already carries a `state_ciphertext`, and a write that carries
  no state (an AshEvents replay, a caller that sends none), are left alone.

  It runs in `change/3`, before the write's transaction, as the other scope
  openers do (`AshEnterprise.Assistant.Changes.OpenThreadScope`): the first
  judgment in a tenant opens the tenant's judged-text scope, and a refused
  write leaves only an empty scope behind.
  """

  use Ash.Resource.Change

  require Logger

  alias AshEnterprise.SystemOne.JudgedState

  @impl true
  def change(changeset, _opts, _context) do
    with true <- changeset.valid?,
         nil <- Ash.Changeset.get_attribute(changeset, :state_ciphertext),
         %{} = judgments <- changeset.context[:judgments],
         {:ok, state} <- Map.fetch(judgments, :judged_state) do
      seal(changeset, state, Map.get(judgments, :judged_state_scope_id))
    else
      _nothing_to_seal -> changeset
    end
  end

  defp seal(changeset, state, scope_id) do
    digest = Ash.Changeset.get_attribute(changeset, :state_digest)

    case JudgedState.seal(state, digest, changeset.to_tenant, scope_id) do
      {:ok, sealed} ->
        Ash.Changeset.force_change_attribute(changeset, :state_ciphertext, sealed)

      # A shred is an operator's choice; anything else is worth a look.
      {:error, :shredded} ->
        log(:info, changeset, :shredded)

      {:error, reason} ->
        log(:warning, changeset, reason)
    end
  end

  defp log(level, changeset, reason) do
    Logger.log(
      level,
      "judgment #{Ash.Changeset.get_attribute(changeset, :id)} recorded without its " <>
        "judged text: #{reason(reason)}"
    )

    changeset
  end

  # The reason's class only: an error's message can carry the values it
  # was about.
  defp reason(reason) when is_atom(reason), do: reason
  defp reason(%{__struct__: module}), do: inspect(module)
  defp reason(_other), do: "unknown"
end
