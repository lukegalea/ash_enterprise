defmodule AshEnterprise.Platform.SystemActor do
  @moduledoc """
  A named non-human actor, for work with no user behind it.

  Every write in this system is attributed. When there is no human — an Oban
  trigger firing a scheduled action, an event replay, a data migration, an
  embedding refresh — the actor is one of these, and the audit log records
  *which* one in `system_actor` rather than leaving `user_id` null.

  That distinction matters to an auditor: "the nightly reconciliation did this"
  and "we did not record who did this" are very different findings, and a single
  nullable `user_id` cannot tell them apart.

  ## Usage

      Ash.create!(changeset, actor: AshEnterprise.Platform.SystemActor.oban())

  ## Deliberately not a resource

  There is no table. A system actor is a compile-time constant, not data — it has
  no lifecycle, nothing references it, and making it a resource would invite
  someone to create new ones at runtime, which would defeat the point of the list
  being auditable and closed.
  """

  @type t :: %__MODULE__{name: atom(), description: String.t()}

  defstruct [:name, :description]

  @actors %{
    oban: "Background job runner (AshOban triggers and scheduled actions).",
    replay: "Event replay rebuilding resource state from the audit log.",
    migration: "A data migration or backfill.",
    seed: "Database seeding, including the initial tenant bootstrap.",
    ai: "An AI agent acting without a human actor. Prefer the human's actor where one exists.",
    system: "Generic fallback. Prefer a specific actor above; this one tells an auditor little."
  }

  for {name, description} <- @actors do
    @doc "The `#{name}` system actor: #{description}"
    def unquote(name)(), do: %__MODULE__{name: unquote(name), description: unquote(description)}
  end

  @doc "All known system actors."
  def all, do: Enum.map(Map.keys(@actors), &apply(__MODULE__, &1, []))

  @doc """
  The value persisted into the audit log's `system_actor` column.

  AshEvents is configured to persist this as a string, so this is the stable
  serialized form. Keep it stable: historical audit rows reference it.
  """
  def to_string(%__MODULE__{name: name}), do: Atom.to_string(name)
end
