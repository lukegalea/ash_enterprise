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

  ## Break-glass sessions

  Whether it is *allowed* is a row: `AshEnterprise.Security.BreakGlassSession`
  records the operator, the subject, the reason, the approver and the expiry,
  and `break_glass/3` returns an impersonating actor only while one is live.
  `acting_as/2` remains the attribution half and does not check for a session;
  a caller that is not itself the check should use `break_glass/3`.
  """

  alias AshEnterprise.Security

  @metadata_key :impersonator_id
  @session_key :break_glass_session_id

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

  @doc """
  `subject` as an actor attributed to `operator`, if a break-glass session is
  live for exactly that pair.

  Live means active, not past `expires_at` (a session is gone at the instant it
  expires) and with both people still active. Anything else -- no session, one
  for another pair, an ended or expired one, arguments that are not people -- is
  `{:error, :no_live_session}`. Options: `:now`.
  """
  @spec break_glass(term(), term(), keyword()) :: {:ok, struct()} | {:error, :no_live_session}
  def break_glass(subject, operator, opts \\ [])

  def break_glass(%{id: subject_id} = subject, %{id: operator_id}, opts)
      when is_binary(subject_id) and is_binary(operator_id) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    # Authorization is off: this answers "is there a live row", for the code that
    # decides whether to build an impersonating actor. It returns no row data.
    case Security.live_break_glass_sessions(operator_id, subject_id, now, authorize?: false) do
      {:ok, [session | _]} ->
        actor =
          subject
          |> acting_as(operator_id)
          |> Ash.Resource.put_metadata(@session_key, session.id)

        {:ok, actor}

      _ ->
        {:error, :no_live_session}
    end
  end

  def break_glass(_subject, _operator, _opts), do: {:error, :no_live_session}
end
