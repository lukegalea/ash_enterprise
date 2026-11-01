defmodule Mix.Tasks.AshEnterprise.Assistant.Enable do
  @shortdoc "Turns the assistant on in a tenant, up to the publish request"

  @moduledoc """
  Takes the assistant (`AshEnterprise.Assistant.Agent`) as far as it can go in one
  tenant without anyone's approval:

      mix ash_enterprise.assistant.enable --org <unique_name or id> --as <user email>

  It registers the assistant from code as the platform baseline, copies it into the
  tenant as a draft and asks for that draft to be published, as the named person
  (`AshEnterprise.Execution.enable_agent_from_code/2`). It prints the approval link and
  what remains. Run again, it asks nothing new: a request already waiting is reported
  with its link, and a published copy as already published.

  It never approves the request and never gives start grants. An administrator other
  than the requester approves at the link. Each member who should use the assistant is
  then given its start grant (`AshEnterprise.Security.AgentStartGrant`).

  `--sole-administrator-approval` first records, as the named person, their
  organization's opt-in to the sole-administrator rule
  (`AshEnterprise.Accounts.Organization.set_sole_administrator_approval/3`): while they
  are its only administrator, they may then approve the request themselves, at the
  same link, and the approval is recorded as a sole-administrator approval. Refused
  unless the person may administer the organization.
  """

  use Mix.Task

  alias AshEnterprise.Accounts
  alias AshEnterprise.Accounts.Organization
  alias AshEnterprise.Mix.Helpers
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security.ActorContext

  require Ash.Query

  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    {opts, _args, _invalid} =
      OptionParser.parse(argv,
        strict: [org: :string, as: :string, sole_administrator_approval: :boolean]
      )

    org = opts[:org] || Mix.raise("--org <unique_name or id> is required")
    email = opts[:as] || Mix.raise("--as <user email> is required")

    # The repo, and Oban for inserting the approval's expiry timer only: no queues, no
    # endpoint (iron law #23).
    Helpers.boot_repo()
    Helpers.boot_oban_inserts()

    organization = organization!(org)
    actor = person!(email, organization)

    if opts[:sole_administrator_approval], do: opt_in!(organization, actor)

    case AshEnterprise.Execution.enable_agent_from_code(AshEnterprise.Assistant.Agent,
           actor: actor,
           tenant: organization.id
         ) do
      {:ok, result} -> report(result, organization)
      {:error, error} -> Mix.raise("could not enable the assistant: " <> Exception.message(error))
    end
  end

  # Operator console: the lookups that find the person run as the seed system actor;
  # everything after runs as them.
  defp organization!(org) do
    query =
      if match?({:ok, _}, Ecto.UUID.cast(org)) and byte_size(org) == 36,
        do: Ash.Query.filter(Organization, id == ^org),
        else: Ash.Query.filter(Organization, unique_name == ^org)

    Ash.read_one!(query, actor: SystemActor.seed()) || Mix.raise("no organization #{org}")
  end

  defp person!(email, organization) do
    case Accounts.get_user_by_email(email, authorize?: false) do
      {:ok, user} ->
        # Built without a tenant, so it is the person's own: their business unit's.
        context = ActorContext.build(user)

        if context.organization_id == organization.id,
          do: ActorContext.attach(user, context),
          else: Mix.raise("#{email} is not a member of #{organization.unique_name}")

      {:error, _} ->
        Mix.raise("no user with email #{email}")
    end
  end

  defp opt_in!(organization, actor) do
    case Organization.set_sole_administrator_approval(organization, true, actor: actor) do
      {:ok, _} ->
        Mix.shell().info("#{organization.unique_name} allows its sole administrator to approve.")

      {:error, error} ->
        Mix.raise("could not record the sole-administrator opt-in: " <> Exception.message(error))
    end
  end

  defp report(%{"outcome" => "already_published"} = result, organization) do
    Mix.shell().info(
      "The assistant (version #{result["version"]}) is already published in " <>
        "#{organization.unique_name}. Nothing to do.\n" <> start_grants()
    )
  end

  defp report(%{"outcome" => outcome} = result, organization) do
    asked =
      if outcome == "requested",
        do: "Asked to publish the assistant (version #{result["version"]})",
        else:
          "A request to publish the assistant (version #{result["version"]}) is already waiting"

    Mix.shell().info("""
    #{asked} in #{organization.unique_name}.
    Approval: #{result["approval_url"]}
    #{approver(result)}
    #{start_grants()}\
    """)
  end

  defp approver(%{"self_approval" => true}),
    do:
      "You are the organization's only administrator and it allows sole-administrator " <>
        "approval: open the link and approve it yourself. The approval is recorded as such."

  defp approver(_result),
    do: "An administrator of the organization other than the requester approves it at the link."

  defp start_grants,
    do:
      "Once it is published, give each member who should use it the assistant agent's " <>
        "start grant."
end
