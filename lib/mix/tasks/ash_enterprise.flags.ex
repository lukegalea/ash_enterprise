defmodule Mix.Tasks.AshEnterprise.Flags do
  @shortdoc "Lists, turns on, targets and turns off a tenant's feature flags"

  @moduledoc """
  A tenant's feature flags (ADR 0072), from the shell, as a named person:

      mix ash_enterprise.flags --org <unique_name or id> --as <email> list
      mix ash_enterprise.flags --org <org> --as <email> on <key>
      mix ash_enterprise.flags --org <org> --as <email> off <key>
      mix ash_enterprise.flags --org <org> --as <email> target <key> \\
        [--team <id>]... [--business-unit <id>]... [--user <id>]... [--percentage <0-100>]

  `list` prints every declared key with this tenant's state, and marks a key the
  deployment killed with `FLAGS_OFF`. `on`, `off` and `target` write the tenant's
  row for a declared key, creating it the first time. Each runs as the named
  person, through `AshEnterprise.Flags`' code interface: they need a grant on
  `AshEnterprise.Flags.Flag` in that tenant, and every write is in the audit log
  under their name. A change reaches a person at their next request or LiveView
  event.
  """

  use Mix.Task

  alias AshEnterprise.Accounts
  alias AshEnterprise.Accounts.Organization
  alias AshEnterprise.Flags
  alias AshEnterprise.Flags.Catalogue
  alias AshEnterprise.Mix.Helpers
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security.ActorContext

  require Ash.Query

  @requirements ["app.config"]

  @switches [
    org: :string,
    as: :string,
    team: :keep,
    business_unit: :keep,
    user: :keep,
    percentage: :integer
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)
    if invalid != [], do: Mix.raise("unknown options: #{inspect(invalid)}")

    org = opts[:org] || Mix.raise("--org <unique_name or id> is required")
    email = opts[:as] || Mix.raise("--as <user email> is required")

    # The repo only: no queues, no endpoint (iron law #23).
    Helpers.boot_repo()

    organization = organization!(org)
    actor = person!(email, organization)
    call = [actor: actor, tenant: organization.id]

    case args do
      ["list"] -> list(call, organization)
      ["on", key] -> write!(key, call, &Flags.turn_on_flag(&1, call), %{state: :on})
      ["off", key] -> write!(key, call, &Flags.turn_off_flag(&1, call), %{state: :off})
      ["target", key] -> target!(key, opts, call)
      _ -> Mix.raise("usage: mix ash_enterprise.flags --org ORG --as EMAIL list|on|off|target")
    end
  end

  defp list(call, organization) do
    rows = call |> Flags.list_flags!() |> Map.new(&{&1.key, &1})

    lines =
      for key <- Catalogue.keys() do
        state = if row = rows[key], do: describe(row), else: "off (no row)"
        killed = if Catalogue.killed?(key), do: "  [killed by FLAGS_OFF]", else: ""
        "  #{key}: #{state}#{killed}\n    #{Catalogue.description(key)}"
      end

    Mix.shell().info(
      "Feature flags in #{organization.unique_name}:\n" <>
        if(lines == [], do: "  (this build declares none)", else: Enum.join(lines, "\n"))
    )
  end

  defp target!(key, opts, call) do
    targets = %{
      team_ids: Keyword.get_values(opts, :team),
      business_unit_ids: Keyword.get_values(opts, :business_unit),
      user_ids: Keyword.get_values(opts, :user),
      percentage: opts[:percentage]
    }

    write!(key, call, &Flags.target_flag(&1, targets, call), Map.put(targets, :state, :targeted))
  end

  # The tenant's row for `key`, updated by `update`, or created with `attrs` the first time.
  defp write!(key, call, update, attrs) do
    unless Catalogue.declared?(key), do: Mix.raise("#{key} is not a declared feature flag")

    result =
      case Flags.get_flag(key, call) do
        {:ok, flag} -> update.(flag)
        {:error, _not_found} -> Flags.set_flag(key, attrs, call)
      end

    case result do
      {:ok, flag} -> Mix.shell().info("#{key}: #{describe(flag)}")
      {:error, error} -> Mix.raise("could not change #{key}: " <> Exception.message(error))
    end
  end

  defp describe(%{state: :targeted} = flag) do
    parts =
      [
        count(flag.user_ids, "person", "people"),
        count(flag.team_ids, "team", "teams"),
        count(flag.business_unit_ids, "business unit", "business units"),
        flag.percentage && "#{flag.percentage}%"
      ]
      |> Enum.reject(&is_nil/1)

    "targeted (" <> if(parts == [], do: "nobody", else: Enum.join(parts, ", ")) <> ")"
  end

  defp describe(flag), do: Atom.to_string(flag.state)

  defp count([], _one, _many), do: nil
  defp count([_], one, _many), do: "1 #{one}"
  defp count(list, _one, many), do: "#{length(list)} #{many}"

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
        context = ActorContext.build(user)

        if context.organization_id == organization.id,
          do: ActorContext.attach(user, context),
          else: Mix.raise("#{email} is not a member of #{organization.unique_name}")

      {:error, _} ->
        Mix.raise("no user with email #{email}")
    end
  end
end
