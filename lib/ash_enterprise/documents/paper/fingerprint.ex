defmodule AshEnterprise.Documents.Paper.Fingerprint do
  @moduledoc """
  What a draft was made from, as a map a later recompute is compared against
  (`AshEnterprise.Documents.PaperDraft`'s sealed `assignments`):

  | Key | What it pins |
  |---|---|
  | `"binding"` | the binding's `id`, the hash of its whole `selection` and its `backend_profile_hash` |
  | `"clause_pins"` | the binding's clause pins, sorted — at draft time exactly the admitted wording |
  | `"decision_definitions"` | each `paper.clause.*` definition used: `key`, `version`, `content_hash` |
  | `"decisions"` | each decision's answer: `key`, `include`, `rule_ids` — excluded clauses too |
  | `"payload_hash"` | the payload's hash, keyed with the run's sealed `payload_hash_key` (as the run's snapshot keys it) |
  | `"title"` | the title the payload was built with |
  | `"subject"` | the kind's subject, so the payload can be rebuilt from the kind's rows |
  | `"output_digest"` | the rendered bytes' digest |

  `moved/4` recomputes every part against the current state and names what
  differs: `:payload`, `:binding`, `:clause_pins`, `:decision_definitions`,
  `:decisions`, in that order. The decisions and their definitions are
  recomputed over the clause keys the tenant's current binding activated
  (`Clauses.bound_keys/2`), the same set issue decides. A part that cannot be
  recomputed — a source that no longer builds a payload, a binding gone, a
  decision that no longer answers — counts as moved: what cannot be shown
  current is never read as current.

  The recompute is read-only: the decisions are re-evaluated without recording
  an evaluation (`record: false`), so checking a draft writes nothing.
  """

  alias AshEnterprise.Documents.Paper
  alias AshEnterprise.Documents.Paper.Actions.Issue
  alias AshEnterprise.Documents.Paper.Clauses
  alias AshEnterprise.Erasure.Shredded

  @version 1

  @typedoc "A part of the fingerprint that can move."
  @type part :: :payload | :binding | :clause_pins | :decision_definitions | :decisions

  @doc """
  The fingerprint of what `Issue.produce/3` returned, for a payload built with
  `title` from the kind's rows for `subject`: `{:ok, map}`, or
  `{:error, reason}` when the run's hash key cannot be read.
  """
  @spec build(map(), String.t(), map(), term()) :: {:ok, map()} | {:error, term()}
  def build(
        %{run: run, binding: binding, payload: payload, selection: selection},
        title,
        subject,
        tenant
      ) do
    with {:ok, payload_hash} <- payload_hash(run, payload, tenant) do
      {:ok,
       %{
         "v" => @version,
         "title" => title,
         "subject" => subject,
         "binding" => binding_entry(binding),
         "clause_pins" => Clauses.binding_pins(binding),
         "decision_definitions" => Enum.map(selection.definitions, &Clauses.definition_entry/1),
         "decisions" => selection.decisions,
         "payload_hash" => payload_hash,
         "output_digest" => run.output_digest
       }}
    end
  end

  @doc "The fingerprint as the sealed binary a draft stores: canonical JSON."
  @spec encode(map()) :: binary()
  def encode(fingerprint), do: AshPaper.Canonical.encode(fingerprint)

  @doc """
  Opens a draft's fingerprint: `{:error, :shredded}` once the run's scope is gone,
  `{:error, :unreadable}` for anything that is not one.
  """
  @spec unseal(struct(), term()) :: {:ok, map()} | {:error, term()}
  def unseal(draft, tenant) do
    with {:ok, loaded} <- Ash.load(draft, :assignments, tenant: tenant, authorize?: false),
         {:ok, binary} <- sealed_value(loaded.assignments),
         {:ok, %{"v" => @version} = fingerprint} <- Jason.decode(binary) do
      {:ok, fingerprint}
    else
      {:error, :shredded} -> {:error, :shredded}
      _unreadable -> {:error, :unreadable}
    end
  end

  defp sealed_value(value) when is_binary(value), do: {:ok, value}
  defp sealed_value(%Shredded{}), do: {:error, :shredded}
  defp sealed_value(_other), do: {:error, :unreadable}

  @doc """
  What moved since `fingerprint` was taken, recomputed against the kind's rows
  for the fingerprint's subject (read as `actor`) and the tenant's current
  binding, admitted wording and published decisions: `[]` when nothing did.
  Nothing is written: the decisions are re-evaluated unrecorded.
  """
  @spec moved(map(), struct(), struct(), term()) :: [part()]
  def moved(fingerprint, run, actor, tenant) do
    kind = run.document_kind
    payload = current_payload(kind, fingerprint, actor: actor, tenant: tenant)
    binding = current_binding(kind, tenant)

    [
      payload: payload_moved?(payload, run, fingerprint, tenant),
      binding: binding_moved?(kind, fingerprint, tenant),
      clause_pins: Clauses.admitted_pins(kind, tenant) != fingerprint["clause_pins"],
      decision_definitions: definitions_moved?(kind, binding, fingerprint, tenant),
      decisions: decisions_moved?(kind, binding, payload, run, fingerprint, tenant)
    ]
    |> Enum.filter(fn {_part, moved?} -> moved? end)
    |> Enum.map(fn {part, _moved?} -> part end)
  end

  # A fingerprint from before subjects were recorded has none: its payload
  # cannot be rebuilt, so it reads as moved.
  defp current_payload(kind, %{"title" => title, "subject" => subject}, opts)
       when is_binary(title) and is_map(subject) do
    case Issue.payload(kind, subject, title, opts) do
      {:ok, payload} -> payload
      {:error, _refused} -> nil
    end
  end

  defp current_payload(_kind, _fingerprint, _opts), do: nil

  defp payload_moved?(nil, _run, _fingerprint, _tenant), do: true

  defp payload_moved?(payload, run, fingerprint, tenant) do
    case payload_hash(run, payload, tenant) do
      {:ok, hash} -> hash != fingerprint["payload_hash"]
      {:error, _reason} -> true
    end
  end

  defp binding_moved?(kind, fingerprint, tenant) do
    with {:ok, schema, layout, _theme} <- Paper.definition(kind),
         {:ok, binding} <- Issue.resolve_binding(kind, tenant),
         {:ok, _theme} <- Issue.pinned_theme(binding, schema, layout) do
      binding_entry(binding) != fingerprint["binding"]
    else
      _gone_or_stale -> true
    end
  end

  # The tenant's binding now, whose clause pins scope what is decided; nil
  # when none resolves, and then nothing scoped by it can be shown current.
  defp current_binding(kind, tenant) do
    case Issue.resolve_binding(kind, tenant) do
      {:ok, binding} -> binding
      {:error, _not_bound} -> nil
    end
  end

  defp definitions_moved?(_kind, nil, _fingerprint, _tenant), do: true

  defp definitions_moved?(kind, binding, fingerprint, tenant),
    do: Clauses.current_definitions(kind, binding, tenant) != fingerprint["decision_definitions"]

  defp decisions_moved?(_kind, nil, _payload, _run, _fingerprint, _tenant), do: true
  defp decisions_moved?(_kind, _binding, nil, _run, _fingerprint, _tenant), do: true

  defp decisions_moved?(kind, binding, payload, run, fingerprint, tenant) do
    case Clauses.decisions(kind, binding, payload, run, tenant, record: false) do
      {:ok, decisions} -> decisions != fingerprint["decisions"]
      {:error, _refused} -> true
    end
  end

  defp binding_entry(binding) do
    %{
      "id" => binding.id,
      "selection_hash" => AshPaper.Canonical.hash(binding.selection),
      "backend_profile_hash" => binding.backend_profile_hash
    }
  end

  # The run's own keyed hash of a payload (`AshPaper.Snapshot.payload_hash/2`,
  # the hash its snapshot embeds), keyed with the run's sealed `payload_hash_key`.
  defp payload_hash(run, payload, tenant) do
    with {:ok, loaded} <- Ash.load(run, :payload_hash_key, tenant: tenant, authorize?: false),
         encoded when is_binary(encoded) <- loaded.payload_hash_key,
         {:ok, key} <- Base.decode64(encoded) do
      {:ok, AshPaper.Snapshot.payload_hash(key, payload)}
    else
      %Shredded{} -> {:error, :shredded}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :unreadable}
    end
  end
end
