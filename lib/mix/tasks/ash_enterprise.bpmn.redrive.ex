defmodule Mix.Tasks.AshEnterprise.Bpmn.Redrive do
  @shortdoc "Drive a tenant's failed trigger dispatches again, as a named person"

  @moduledoc """
  Drives again every failed trigger dispatch whose event lies in a range of one tenant's
  log, each under the subscription version on its row, as the person named by `--as`
  (`AshEnterprise.Bpmn.Redrive.redrive_failed`).

      mix ash_enterprise.bpmn.redrive --tenant acme --as ops@example.com --from-sequence 1200 --to-sequence 1350
      mix ash_enterprise.bpmn.redrive --tenant acme --as ops@example.com --since 2026-11-12T00:00:00Z

  `--tenant` takes the organization's unique name or id, `--as` the person's email or id.
  The range is `--from-sequence`/`--to-sequence` (inclusive), `--since` (inclusive) and
  `--until` (exclusive) as ISO 8601 instants, or both; at least one bound is required.

  The person needs a global `write` on the tenant's recipes, as publishing one does. A
  standing-grant recipe's grant is checked again now, and a version whose grant was revoked
  or lapsed, or whose publisher has gone, records `no_authority` and starts nothing. Each
  re-drive is recorded (`AshEnterprise.Bpmn.Redrive`), and running the task again starts
  nothing twice.
  """

  use Mix.Task

  require Ash.Query

  alias AshEnterprise.Accounts
  alias AshEnterprise.Accounts.{Organization, User}
  alias AshEnterprise.Bpmn.Redrive
  alias AshEnterprise.Mix.Helpers
  alias AshEnterprise.Security.ActorContext

  @requirements ["app.config"]

  @switches [
    tenant: :string,
    as: :string,
    from_sequence: :integer,
    to_sequence: :integer,
    since: :string,
    until: :string
  ]

  @impl Mix.Task
  def run(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, [], []} ->
        tenant = opts[:tenant] || Mix.raise("--tenant is required")
        person = opts[:as] || Mix.raise("--as is required: a re-drive is a person's act")
        range = range!(opts)

        # The Repo, and Oban for inserts only: a re-drive starts processes, whose first
        # advance is a job the application's own nodes run. No queues, no endpoint
        # (iron law #23).
        Helpers.boot_repo()
        Helpers.boot_oban_inserts()
        redrive(tenant, person, range)

      _other ->
        Mix.raise(
          "usage: mix ash_enterprise.bpmn.redrive --tenant NAME_OR_ID --as EMAIL_OR_ID " <>
            "[--from-sequence N] [--to-sequence N] [--since ISO8601] [--until ISO8601]"
        )
    end
  end

  defp redrive(tenant_ref, person_ref, range) do
    organization = organization!(tenant_ref)
    actor = person!(person_ref, organization.id)

    case Redrive.redrive_failed(range, actor: actor, tenant: organization.id) do
      {:ok, []} ->
        Mix.shell().info("#{organization.unique_name}: no failed dispatch in that range")

      {:ok, redrives} ->
        Mix.shell().info("#{organization.unique_name}: #{length(redrives)} re-driven")
        Enum.each(redrives, &Mix.shell().info(line(&1)))

      {:error, error} ->
        Mix.raise("could not re-drive: #{Exception.message(Ash.Error.to_error_class(error))}")
    end
  end

  defp line(redrive) do
    "  event #{redrive.event_sequence} (#{redrive.event_id}): #{redrive.outcome}" <>
      if(redrive.reason, do: " (#{redrive.reason})", else: "")
  end

  defp range!(opts) do
    range =
      %{
        from_sequence: opts[:from_sequence],
        to_sequence: opts[:to_sequence],
        since: instant!(opts[:since], "--since"),
        until: instant!(opts[:until], "--until")
      }
      |> Map.reject(fn {_bound, value} -> is_nil(value) end)

    if range == %{},
      do: Mix.raise("give a range: --from-sequence/--to-sequence, --since/--until, or both"),
      else: range
  end

  defp instant!(nil, _flag), do: nil

  defp instant!(text, flag) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      {:error, _} -> Mix.raise("#{flag} is not an ISO 8601 instant: #{inspect(text)}")
    end
  end

  # Looked up without authorization: the task names the tenant and the person, and the
  # re-drive itself runs on that person's grants.
  defp organization!(ref) do
    query =
      case uuid(ref) do
        {:ok, id} -> Ash.Query.filter(Organization, id == ^id)
        :error -> Ash.Query.filter(Organization, unique_name == ^ref)
      end

    query
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> Mix.raise("no organization #{inspect(ref)}")
      organization -> organization
    end
  end

  defp person!(ref, tenant) do
    found =
      case uuid(ref) do
        {:ok, id} -> Ash.get(User, id, authorize?: false)
        :error -> Accounts.get_user_by_email(ref, authorize?: false)
      end

    case found do
      {:ok, %User{} = user} ->
        # Built without a tenant, so it is the person's own: their business unit's.
        context = ActorContext.build(user)

        if context.organization_id == tenant,
          do: ActorContext.attach(user, context),
          else: Mix.raise("#{ref} is not a member of that organization")

      _none ->
        Mix.raise("no person #{inspect(ref)}")
    end
  end

  # Only a 36-character string is an id: `Ecto.UUID.cast/1` also takes any 16-byte binary as
  # a raw UUID, which a sixteen-character name is.
  defp uuid(ref) do
    case {byte_size(ref), Ecto.UUID.cast(ref)} do
      {36, {:ok, id}} -> {:ok, id}
      _other -> :error
    end
  end
end
