defmodule Mix.Tasks.AshEnterprise.Packs.Install do
  @shortdoc "Install a recipe pack into one tenant as drafts, as a named person"

  @moduledoc """
  Installs a recipe pack from `priv/packs/<name>/` into one tenant as drafts
  (`AshEnterprise.Bpmn.Packs`): a draft process definition per process and a draft recipe
  per recipe, created as the person named by `--as`, on their own grants.

      mix ash_enterprise.packs.install soc2_cc6_3 --tenant acme --as admin@example.com
      mix ash_enterprise.packs.install --list

  `--tenant` takes the organization's unique name or id. Nothing installed runs: a person
  publishes the process (the designer) and then the recipe (`/app/triggers`). Running it
  again installs nothing more, and reports each key as existing.
  """

  use Mix.Task

  require Ash.Query

  alias AshEnterprise.Accounts
  alias AshEnterprise.Accounts.Organization
  alias AshEnterprise.Bpmn.{Packs, Subscription}
  alias AshEnterprise.Mix.Helpers
  alias AshEnterprise.Security.ActorContext

  @requirements ["app.config"]

  @switches [tenant: :string, as: :string, list: :boolean]

  @impl Mix.Task
  def run(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {[list: true], [], []} ->
        Enum.each(Packs.names(), fn name -> Mix.shell().info(name) end)

      {opts, [name], []} ->
        tenant = opts[:tenant] || Mix.raise("--tenant is required")
        email = opts[:as] || Mix.raise("--as is required: a pack is installed by a person")
        # Repo only: no Oban, no endpoint (iron law #23). Installing writes drafts and
        # their audit events, and starts nothing.
        Helpers.boot_repo()
        install(name, tenant, email)

      _other ->
        Mix.raise(
          "usage: mix ash_enterprise.packs.install NAME --tenant UNIQUE_NAME_OR_ID --as EMAIL"
        )
    end
  end

  defp install(name, tenant_ref, email) do
    organization = organization!(tenant_ref)
    actor = person!(email, organization.id)

    case Subscription.install_pack(name, actor: actor, tenant: organization.id) do
      {:ok, result} ->
        Mix.shell().info(
          "#{organization.unique_name}: pack #{result.pack} installed as drafts\n" <>
            lines("process", result.processes) <>
            lines("recipe", result.recipes) <>
            "Nothing runs until a person publishes the process and then the recipe."
        )

      {:error, error} ->
        Mix.raise(
          "could not install #{name}: #{Exception.message(Ash.Error.to_error_class(error))}"
        )
    end
  end

  defp lines(kind, by_key),
    do: Enum.map_join(by_key, fn {key, what} -> "  #{kind} #{key}: #{what}\n" end)

  # Looked up without authorization: the task names the tenant and the person, and the
  # install itself runs on that person's grants.
  defp organization!(ref) do
    Organization
    |> by_ref(ref)
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> Mix.raise("no organization #{inspect(ref)}")
      organization -> organization
    end
  end

  # Only a 36-character string is an id: `Ecto.UUID.cast/1` also takes any 16-byte binary as a
  # raw UUID, which a unique name of sixteen characters is.
  defp by_ref(query, ref) do
    case {byte_size(ref), Ecto.UUID.cast(ref)} do
      {36, {:ok, id}} -> Ash.Query.filter(query, id == ^id)
      _name -> Ash.Query.filter(query, unique_name == ^ref)
    end
  end

  defp person!(email, tenant) do
    case Accounts.get_user_by_email(email, authorize?: false) do
      {:ok, user} ->
        # Built without a tenant, so it is the person's own: their business unit's.
        context = ActorContext.build(user)

        if context.organization_id == tenant,
          do: ActorContext.attach(user, context),
          else: Mix.raise("#{email} is not a member of that organization")

      {:error, _} ->
        Mix.raise("no person with email #{inspect(email)}")
    end
  end
end
