defmodule AshEnterprise.Security.Impersonation do
  @moduledoc """
  Acting as someone else, on the record.

  Support engineers look at customer accounts. It is the single most common
  privileged operation in B2B software and the one auditors ask about first,
  because it is the one where "who did this" has two answers and most systems
  keep only one.

  This is the machinery for keeping both. An impersonating actor is an ordinary
  user struct carrying the operator's id in Ash metadata, and
  `AshEnterprise.Platform.Changes.StampProvenance` writes it into the record's
  `created_on_behalf_by_id` / `modified_on_behalf_by_id` — the Dataverse columns
  the platform has always declared for exactly this and, until now, never filled.
  `AshEnterprise.Platform.Correlation` carries it into every audit event, so a
  trail read afterwards names the customer *and* the engineer.

      actor = AshEnterprise.Security.Impersonation.acting_as(customer, operator)
      MyApp.Domain.do_something(input, actor: actor)

  The customer remains the actor. That is deliberate: authorization must be
  exactly what the customer could have done themselves, or impersonation becomes
  a privilege-escalation path rather than a support tool. What the operator adds
  is attribution, never reach.

  ## What this does not do yet

  It does not decide **who may impersonate whom**, and it does not record a
  session — a start, an end, and a stated reason — as a first-class row. Both are
  needed before this is a complete break-glass story, and both are named as open
  on the roadmap rather than implied by the presence of this module. What exists
  here is the attribution half: if impersonation happens, it is recorded
  everywhere an ordinary action is recorded, with the second name attached.
  """

  @metadata_key :impersonator_id

  @doc """
  Returns `subject` as an actor whose actions are attributed to `operator` as
  well.

  `operator` may be a user struct or an id.
  """
  @spec acting_as(struct(), struct() | Ash.UUID.t() | nil) :: struct()
  def acting_as(subject, nil), do: subject

  def acting_as(subject, %{id: operator_id}), do: acting_as(subject, operator_id)

  def acting_as(subject, operator_id) when is_binary(operator_id) do
    Ash.Resource.put_metadata(subject, @metadata_key, operator_id)
  end

  @doc "The operator behind an actor, or `nil` when the actor is acting as themselves."
  @spec impersonator_id(term()) :: Ash.UUID.t() | nil
  def impersonator_id(%{__metadata__: metadata}), do: Map.get(metadata, @metadata_key)
  def impersonator_id(_), do: nil

  @doc "Whether this actor is acting on someone else's behalf."
  @spec impersonating?(term()) :: boolean()
  def impersonating?(actor), do: not is_nil(impersonator_id(actor))
end
