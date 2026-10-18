defmodule AshEnterprise.Assistant.Changes.InheritConversationScope do
  @moduledoc """
  Names the conversation's erasure scope on a reply draft, so the seal that
  follows (`AshEnterprise.Erasure.Changes.SealUnderScope`) puts the body under
  the same key as the mail or Slack it answers.

  The conversation is read **as the actor**: a conversation they may not read
  (someone else's — Conversation is owner-only) is "not found", and no draft
  is written. In `change/3` rather than a hook because the seal runs in
  `change/3` and Ash checks required attributes before hooks.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshEnterprise.Canonical.Conversation

  @impl true
  def change(changeset, _opts, context) do
    conversation_id = Ash.Changeset.get_attribute(changeset, :conversation_id)
    opts = context |> Ash.Context.to_opts() |> Keyword.take([:actor, :tenant, :tracer])

    with id when not is_nil(id) <- conversation_id,
         {:ok, %Conversation{erasure_scope_id: scope_id}} <-
           Conversation
           |> Ash.Query.filter(id == ^id)
           |> Ash.Query.select([:id, :erasure_scope_id])
           |> Ash.read_one(Keyword.put(opts, :authorize?, true)) do
      Ash.Changeset.force_change_attribute(changeset, :erasure_scope_id, scope_id)
    else
      _ -> Ash.Changeset.add_error(changeset, field: :conversation_id, message: "not found")
    end
  end
end
