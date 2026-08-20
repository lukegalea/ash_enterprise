defmodule Mix.Tasks.AshEnterprise.Bpmn.Setup do
  @shortdoc "Publish baselines, create triggers, and leave running processes behind"

  @moduledoc """
  Makes the process surfaces show something real.

  Publishes the baselines, creates the access-request trigger in each seeded tenant, and then
  **drives four requests down all three branches of the gateway** so that every screen has
  something on it, and no branch of the published diagram is left unexercised:

    1. `low` — granted with no human involved, proof the engine runs end to end
    2. `high`, from an elevated request with a thin justification — an executive approval
    3. `high`, from a privileged request — the same branch by a different rule
    4. `medium` — a manager approval, so the task list has a row and `ManagerApproval` runs

  It also customizes one tenant's risk decision, so the drift badge on `/app/processes` has a
  subject rather than being a feature nothing demonstrates.

  The fourth request is the one to be careful with when editing: the trigger's guard is
  `string length(data.justification) > 30` and the risk table's boundary is `< 40`, so only a
  standard-tier justification of 31 to 39 characters reaches `medium` at all. Three requests
  route to `low`, `high` and `high`, which is why `ManagerApproval` had never once executed
  before it was added.

  ## Why it drains the queue

  Oban runs asynchronously in dev, so a seed that submits four requests and exits leaves four
  processes sitting on their start nodes. Every screenshot would then show an idle system that
  technically works, which is the difference between a demo and a picture of one. This drains
  between steps.

      mix ash_enterprise.bpmn.setup
  """

  use Mix.Task

  require Ash.Query

  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Process.{Resolver, Trigger}
  alias AshEnterprise.Process.Triggers.SweepWorker
  alias AshEnterprise.Security.{AccessRequest, Role}

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.start")
    Mix.Task.run("ash_enterprise.bpmn.publish")

    for organization <- tenants() do
      seed_tenant_demo(organization)
    end

    Mix.shell().info("\nDone. Visit /app/tasks, /app/processes and /app/triggers.")
  end

  defp seed_tenant_demo(organization) do
    Mix.shell().info("\n#{organization.unique_name}:")

    # The catalogue itself is derived from the resources that exist, so a resource added after
    # the last seed has no privileges at all -- not merely ungranted ones. Idempotent.
    Seeder.seed_privileges()

    # New resources mean new privileges, and the Administrator role was granted its set at
    # provisioning time. Without this the seeded admin cannot submit a request on a resource
    # that did not exist when their role was built -- a forbidden write that reads as a bug in
    # the resource rather than as a stale grant.
    case Seeder.regrant_administrator_privileges(organization.id) do
      0 -> :ok
      n -> Mix.shell().info("  granted #{n} new privilege(s) to Administrator")
    end

    ensure_trigger(organization.id)
    role = ensure_role(organization.id)

    case first_user(organization.id) do
      nil ->
        Mix.shell().info("  (no user in this tenant; skipping requests)")

      user ->
        seed_requests(organization.id, role, user)
        # One tenant gets its own copy, so the catalogue has something to say about drift.
        if organization.unique_name == "example", do: fork_for_demo(organization.id)
    end
  end

  # Every seeded tenant except the platform organization, which owns baselines and is not a
  # customer -- it has no users and nothing should run in it.
  defp tenants do
    platform = Resolver.platform_tenant()

    AshEnterprise.Accounts.Organization
    |> Ash.Query.for_read(:read)
    |> Ash.read!(actor: SystemActor.seed(), authorize?: false)
    |> Enum.reject(&(&1.id == platform))
  end

  defp ensure_trigger(tenant) do
    opts = [actor: SystemActor.process(), tenant: tenant]

    existing =
      Trigger
      |> Ash.Query.for_read(:published)
      |> Ash.Query.filter(key == "access_request.submitted")
      |> Ash.read!(opts)

    if existing == [] do
      Trigger
      |> then(fn _ ->
        Trigger.create!(
          %{
            key: "access_request.submitted",
            match_resource: "AshEnterprise.Security.AccessRequest",
            match_action: "submit",
            match_action_type: :create,
            guard_feel: "string length(data.justification) > 30",
            process_key: "access_request.grant"
          },
          opts
        )
      end)
      |> Trigger.publish!(opts)

      Mix.shell().info("  trigger access_request.submitted published")
    else
      Mix.shell().info("  trigger access_request.submitted already published")
    end
  end

  defp ensure_role(tenant) do
    opts = [actor: SystemActor.seed(), tenant: tenant]

    Role
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(name == "Report Reader")
    |> Ash.read_one!(opts)
    |> case do
      nil ->
        Role
        |> Ash.Changeset.for_create(:create, %{name: "Report Reader"}, opts)
        |> Ash.create!()

      role ->
        role
    end
  end

  defp first_user(tenant) do
    AshEnterprise.Accounts.User
    |> Ash.Query.for_read(:read)
    |> Ash.Query.limit(1)
    |> Ash.read!(actor: SystemActor.seed(), tenant: tenant, authorize?: false)
    |> List.first()
  end

  defp seed_requests(tenant, role, user) do
    if already_seeded?(tenant) do
      Mix.shell().info("  requests already seeded")
    else
      # Establish the cursor *before* submitting anything. A cursor created afterwards starts
      # at the current high-water mark -- correct, because a trigger fires on what happens
      # after it exists -- which would put every request seeded here behind it and dispatch
      # none of them. Publishing a trigger normally does this; a tenant whose cursor was
      # removed, or one provisioned after the trigger, needs it doing again.
      SweepWorker.ensure_cursor(tenant)

      submit(
        tenant,
        role,
        user,
        :standard,
        "Quarterly compliance reporting for the EMEA region, as the auditors asked."
      )

      submit(tenant, role, user, :elevated, "Elevated for the migration window.")

      submit(
        tenant,
        role,
        user,
        :privileged,
        "Privileged access for the incident review, scoped to the affected unit only."
      )

      # The `medium` request, and the reason it is written to a length rather than to read
      # nicely. The trigger's guard is `string length(data.justification) > 30` and the risk
      # table's boundary is `< 40`, so a request only reaches `medium` -- and therefore only
      # reaches `ManagerApproval` -- with a standard-tier justification between 31 and 39
      # characters. This one is 37.
      #
      # Without it the whole middle branch of the diagram was unreachable from the seed: the
      # other three route to `low`, `high` and `high`, so both approval tasks were executive
      # ones and `ManagerApproval` had never executed. A demo that leaves a branch of its own
      # diagram unexercised is the kind of thing a screenshot hides rather than reveals.
      submit(tenant, role, user, :standard, "Standing report access for month-end.")

      drain(tenant)
      Mix.shell().info("  four requests submitted and dispatched")
    end
  end

  # One tenant is given its own copy of the process, so the designer opens a real diagram and
  # the catalogue has something to say about drift. Without it every tenant runs the baseline,
  # the customization story has no subject, and the designer -- which creates a draft from a
  # blank template when a tenant has none -- shows an empty canvas.
  defp fork_for_demo(tenant) do
    case Resolver.fork(:process, "access_request.grant", tenant) do
      {:ok, draft} ->
        Mix.shell().info("  forked access_request.grant as draft v#{draft.version}")

      {:error, reason} ->
        Mix.shell().info("  could not fork: #{inspect(reason)}")
    end
  end

  defp already_seeded?(tenant) do
    AccessRequest
    |> Ash.Query.for_read(:read)
    |> Ash.Query.limit(1)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
    |> Enum.any?()
  end

  defp submit(tenant, role, user, tier, justification) do
    AccessRequest.submit!(
      %{
        justification: justification,
        requested_role_tier: tier,
        requested_role_id: role.id
      },
      actor: user,
      tenant: tenant
    )
  end

  # See the moduledoc. Without this every process sits on its start node and every screen
  # shows a system that has done nothing.
  defp drain(tenant) do
    SweepWorker.perform(%Oban.Job{args: %{"tenant" => tenant}})

    # Both queues, not just `:bpmn`. Jobs enqueued before the queue fix landed sit on
    # `:default`, and a seed that drained only one left processes parked on their start nodes
    # -- a demo of a system that has done nothing, which is the failure this whole task exists
    # to avoid.
    for queue <- [:bpmn, :default] do
      Oban.drain_queue(queue: queue, with_recursion: true)
    end
  end
end
