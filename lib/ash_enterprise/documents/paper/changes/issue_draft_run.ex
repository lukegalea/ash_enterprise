defmodule AshEnterprise.Documents.Paper.Changes.IssueDraftRun do
  @moduledoc """
  The host side of `PaperDraft.apply` (R10): the person's apply of an approved,
  current draft issues its run — with no re-render.

      # in AshEnterprise.Documents.PaperDraft
      changes do
        change AshEnterprise.Documents.Paper.Changes.IssueDraftRun,
          on: [:update], where: action_is(:apply)
      end

  The fragment's `apply` validations (approved, correct, current) have already
  passed. Inside the action's transaction, before the disposition is written:

    1. the draft's fingerprint is unsealed (a shredded scope refuses);
    2. the run is a `:draft` run that rendered and passed its read-back, its
       `output_digest` is the fingerprint's, and the stored
       `AshEvidence.DocumentVersion` with that digest hashes to it — the issued
       bytes are exactly the approved bytes;
    3. nothing the draft was made from has moved, recomputed here, inside the
       transaction, as the person applying it
       (`AshEnterprise.Documents.Paper.Fingerprint.moved/4`, read-only): the
       check `issue_draft` makes before it applies is repeated where the
       apply commits, so a change between that check and the apply is
       refused, not issued;
    4. the run moves to `:issued` (`PaperRun.promote_draft`, machinery-only,
       performed here as the apply's own bookkeeping).

  Any refusal is an error on the apply: the transaction rolls back, the draft
  stays approved and the run stays a draft.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshEnterprise.Documents.Paper.Fingerprint
  alias AshEnterprise.Documents.PaperRun

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, &issue_run(&1, context.actor))
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: {:not_atomic, "apply issues the draft's run"}

  defp issue_run(changeset, actor) do
    draft = changeset.data
    tenant = changeset.tenant

    with {:ok, fingerprint} <- Fingerprint.unseal(draft, tenant),
         {:ok, run} <- Ash.get(PaperRun, draft.run_id, tenant: tenant, authorize?: false),
         :ok <- same_bytes(run, fingerprint["output_digest"], tenant),
         :ok <- unmoved(fingerprint, run, actor, tenant),
         {:ok, _issued} <-
           run
           |> Ash.Changeset.for_update(:promote_draft, %{}, tenant: tenant)
           |> Ash.update(authorize?: false) do
      changeset
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :disposition,
          message: "the draft cannot be issued: " <> reason_text(reason)
        )
    end
  end

  defp same_bytes(%PaperRun{output_digest: digest}, digest, tenant) when is_binary(digest) do
    AshEvidence.DocumentVersion
    |> Ash.Query.filter(sha256 == ^digest)
    |> Ash.read_one(tenant: tenant, authorize?: false)
    |> case do
      {:ok, %{bytes: bytes}} when is_binary(bytes) ->
        if sha256(bytes) == digest, do: :ok, else: {:error, :bytes_changed}

      {:ok, _missing} ->
        {:error, :bytes_missing}

      {:error, error} ->
        {:error, error}
    end
  end

  defp same_bytes(_run, _digest, _tenant), do: {:error, :digest_changed}

  defp unmoved(fingerprint, run, actor, tenant) do
    case Fingerprint.moved(fingerprint, run, actor, tenant) do
      [] -> :ok
      moved -> {:error, {:moved, moved}}
    end
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp reason_text({:moved, moved}),
    do: "what it was made from has moved (#{Enum.map_join(moved, ", ", &to_string/1)})"

  defp reason_text(%{__exception__: true} = error), do: Exception.message(error)
  defp reason_text(other), do: inspect(other)
end
