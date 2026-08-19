defmodule AshEnterprise.Process.ActionInvoker do
  @moduledoc """
  Runs the Ash action a service task names.

  This is the whole of what a process is allowed to *do*, and it is deliberately a thin
  translation rather than a place with any judgement in it. A node says `action="grant_role"`;
  this finds that action and calls it, as the actor the engine is carrying, through the
  ordinary action layer — so its policies, its validations and its audit entry are exactly the
  ones a human clicking a button would get.

  ## Why the allowlist exists

  A service task's action name comes out of tenant-authored BPMN XML. Without a closed list,
  drawing a box and typing an action name would be a way to invoke *any* action in the
  application — which would make the diagram editor the most powerful surface in the product
  and the process graph a place business logic could hide.

  So the actions a process may invoke are declared here, in code, reviewed like code. Adding
  one is a deliberate act by someone who can see what it does. That is the same argument
  `.mcp.json`'s explicit tool allowlist makes for the agent surface, and it is stronger here
  because the caller is a diagram rather than a person.

  ## Which actor a service task acts as

  `AshEnterprise.Platform.SystemActor.process()`, always — not the actor the engine happens to
  be carrying.

  The engine's own actor is an `AshBpmn.SystemActor`, a struct this application's policy set
  has never heard of: it satisfies neither the grant union nor the `SystemActor` bypass, so a
  service task calling a host action with it is simply forbidden. That presents as a process
  stuck mid-flow with no error surfaced anywhere, which is how it was found.

  Substituting a named platform actor is also the right answer rather than merely a working
  one. A service task is the *engine* doing something, and the trail should say so. The human
  is not lost: they are on the instance's `started_by_id`, on the request's `created_by_id`,
  and on `decided_by_id` for whatever approval led here — three distinct facts, which is more
  than attributing all of them to one person would have said.

  ## Idempotency is the caller's problem, and it is real

  Oban redelivers. A node may execute twice, and the token claim gate makes a *double advance*
  safe without making a *double action* safe. Every action named here must tolerate being
  invoked a second time with the same subject — which in practice means it should be
  expressible as "make this true" rather than "do this again".
  """

  @behaviour AshBpmn.ActionInvoker

  require Logger

  # `"name" => fun/1`. Deliberately explicit: see the moduledoc. Each entry is reviewed like
  # code because a diagram is what names it.
  @allowed %{
    "record_risk" => &__MODULE__.record_risk/1,
    "grant_role" => &__MODULE__.grant_role/1,
    "reject_request" => &__MODULE__.reject_request/1
  }

  @impl true
  def invoke(action, ctx) do
    case Map.fetch(@allowed, action) do
      {:ok, fun} ->
        run(fun, action, ctx)

      :error ->
        # An unknown action fails the node rather than being ignored. A service task that
        # silently did nothing would leave a process that looks like it worked, which is worse
        # than one that stops.
        {:error,
         {:action_not_allowed, action,
          "add it to AshEnterprise.Process.ActionInvoker's allowlist if a process should be " <>
            "able to invoke it"}}
    end
  end

  # ── the allowed actions ──────────────────────────────────────────────────
  #
  # Each is an ordinary Ash action called as the actor the engine is carrying, so its policies,
  # its validations and its audit entry are the ones a person clicking a button would get. The
  # process orchestrates; it does not get a privileged path to the data.

  @doc "Writes back the risk tier the decision produced, so the request shows why it routed."
  def record_risk(ctx) do
    with %{} = subject <- ctx[:subject],
         tier when is_binary(tier) <- routing(ctx)["risk_tier"] do
      AshEnterprise.Security.AccessRequest.record_risk!(
        subject,
        risk_atom(tier),
        engine_opts(ctx)
      )

      :ok
    else
      _ -> {:error, :no_risk_tier_to_record}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Assigns the requested role, and records the assignment on the request.

  Idempotent by construction, which the moduledoc requires of everything here: an assignment
  that already exists is found rather than duplicated, so an Oban redelivery grants once.
  """
  def grant_role(ctx) do
    subject = ctx[:subject]
    opts = engine_opts(ctx)

    user_role =
      existing_assignment(subject, opts) ||
        AshEnterprise.Security.UserRole
        |> Ash.Changeset.for_create(
          :assign,
          %{
            user_id: subject.created_by_id,
            role_id: subject.requested_role_id,
            scoping_business_unit_id: subject.scoping_business_unit_id
          },
          opts
        )
        |> Ash.create!()

    AshEnterprise.Security.AccessRequest.grant!(subject, user_role.id, opts)
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Records that the request was refused."
  def reject_request(ctx) do
    AshEnterprise.Security.AccessRequest.reject!(ctx[:subject], engine_opts(ctx))

    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp existing_assignment(subject, opts) do
    require Ash.Query

    AshEnterprise.Security.UserRole
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      user_id == ^subject.created_by_id and role_id == ^subject.requested_role_id
    )
    |> Ash.Query.limit(1)
    |> Ash.read!(opts)
    |> List.first()
  end

  defdelegate engine_opts(ctx), to: AshEnterprise.Process.EngineContext

  # The risk tiers are a closed set declared on the resource, so the atom always exists. Using
  # `to_existing_atom` rather than `to_atom` because the value came from a decision table a
  # tenant authored, and an atom created from tenant input is never collected.
  defp risk_atom(tier) when is_binary(tier), do: String.to_existing_atom(tier)

  defp routing(ctx) do
    case ctx[:token] do
      %{routing: routing} when is_map(routing) -> routing
      _ -> %{}
    end
  end

  defp run(fun, action, ctx) do
    fun.(ctx)
  rescue
    e ->
      Logger.error("process action #{action} raised: #{Exception.message(e)}")
      {:error, {:action_raised, action, Exception.message(e)}}
  end
end
