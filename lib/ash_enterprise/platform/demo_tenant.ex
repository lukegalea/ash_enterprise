defmodule AshEnterprise.Platform.DemoTenant do
  @moduledoc """
  The one tenant `mix ash_enterprise.demo` is allowed to write to.

  The demo fills a tenant with a business-unit tree, people, a synthetic clinic and an MDM
  walk-through. Run against a database that already holds real tenants, that must change
  nothing of theirs. So the demo never picks a tenant: it owns a dedicated one, named by
  a fixed slug (`slug/0`, the organization's `unique_name`).

    * `provision!/0` finds that organization or creates it (with an administrator,
      `admin_email/0`), and returns it. It never looks at another organization.
    * `populate!/1` takes the organization it is given and raises unless it is the demo
      tenant, so a caller holding another tenant's id cannot fill it.
    * `run!/0` is both, in that order, and returns what the demo task prints.

  Running it twice is a no-op the second time: every step it calls finds its own rows
  first (`AshEnterprise.Platform.DemoData`, `AshEnterprise.Credentialing.DemoData`,
  `AshEnterprise.Mdm.DemoData`).

  Two things are shared with the rest of the database and are handled so they stay safe:

    * the demo people have fixed example addresses, and a user's email is unique across
      the database. A person already living in another tenant is not moved here:
      `populate!/1` refuses before it writes anything (`DemoData.populate/1`, which tests
      call on tenants of their own, is not so careful);
    * the platform baselines the MDM walk-through needs (the match bands and the steward
      review process) are published into the platform organization only when missing or
      older than the checked-in files, exactly what a deploy does.
  """

  require Ash.Query

  alias AshEnterprise.Accounts.{BusinessUnit, Organization, User}
  alias AshEnterprise.Credentialing.DemoData, as: ClinicData
  alias AshEnterprise.Mdm.DemoData, as: MdmData
  alias AshEnterprise.Platform.{DemoData, Seeder}

  # Sobelow reads `@sobelow_skip` from the source AST; persisting it keeps
  # `--warnings-as-errors` from calling it unused (see Zones).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @slug "clinic-demo"
  @name "Riverside Demo"
  @admin_email "demo-admin@example.com"

  @doc "The demo tenant's `unique_name`."
  @spec slug() :: String.t()
  def slug, do: @slug

  @doc "The demo tenant's administrator."
  @spec admin_email() :: String.t()
  def admin_email, do: @admin_email

  @doc "Whether `organization` is the demo tenant."
  @spec demo?(Organization.t()) :: boolean()
  def demo?(organization), do: to_string(organization.unique_name) == @slug

  @doc "The demo tenant, or `nil` when it has not been provisioned."
  @spec find() :: Organization.t() | nil
  def find do
    Organization
    |> Ash.Query.filter(unique_name == ^@slug)
    |> Ash.read_one!(authorize?: false)
  end

  @doc "The demo tenant, created with its administrator when it does not exist yet."
  @spec provision!(keyword()) :: Organization.t()
  def provision!(opts \\ []) do
    find() ||
      Seeder.seed_tenant(
        name: @name,
        unique_name: @slug,
        email: @admin_email,
        password: Keyword.get(opts, :password, DemoData.default_password())
      ).organization
  end

  @doc """
  The password in the file at `path`; when there is no file, a random one, written to `path`
  (mode 0600, the directory created) first. It is never returned to anyone who prints it:
  the file is where it is read.
  """
  # The path is the operator's `--password-file` argument, never request input.
  @sobelow_skip ["Traversal.FileModule"]
  @spec password_from_file!(Path.t()) :: String.t()
  def password_from_file!(path) do
    case File.read(path) do
      {:ok, contents} ->
        String.trim(contents)

      {:error, :enoent} ->
        password = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64()
        File.mkdir_p!(Path.dirname(path))
        File.touch!(path)
        File.chmod!(path, 0o600)
        File.write!(path, password)
        password
    end
  end

  @doc """
  Fills the demo tenant `organization`; raises `ArgumentError` for any other. `opts` as for `run!/1`.
  Returns `%{counts:, clinic:, mdm:}`, `mdm` being `nil` when the demo administrator is
  missing.
  """
  @spec populate!(Organization.t(), keyword()) :: map()
  def populate!(organization, opts \\ []) do
    unless demo?(organization) do
      raise ArgumentError,
            "refusing to populate #{inspect(organization.unique_name)}: the demo writes only to " <>
              "the #{inspect(@slug)} tenant"
    end

    tenant = organization.id
    refuse_foreign_people!(tenant)
    counts = DemoData.populate(tenant, opts)
    clinic = ClinicData.populate(tenant, opts)

    admin =
      User
      |> Ash.Query.filter(email == ^@admin_email)
      |> Ash.read_one!(tenant: tenant, authorize?: false)

    %{counts: counts, clinic: clinic, mdm: admin && MdmData.populate(tenant, admin)}
  end

  # An email is unique across the database, and the demo's `ensure_user!` takes a person it
  # finds by email into the tenant it is filling. Someone who lives in another tenant would be
  # taken out of it.
  defp refuse_foreign_people!(tenant) do
    emails = DemoData.emails() ++ ClinicData.emails()

    for user <- User |> Ash.Query.filter(email in ^emails) |> Ash.read!(authorize?: false),
        not lives_in?(user, tenant) do
      raise ArgumentError,
            "#{user.email} already belongs to another tenant, and the demo does not move people"
    end

    :ok
  end

  # A person with no business unit yet lives nowhere, and is free to take.
  defp lives_in?(%{owning_business_unit_id: nil}, _tenant), do: true

  defp lives_in?(user, tenant) do
    BusinessUnit
    |> Ash.Query.filter(id == ^user.owning_business_unit_id)
    |> Ash.exists?(tenant: tenant, authorize?: false)
  end

  @doc """
  Provisions the demo tenant and fills it. Safe on a database that holds other tenants.

  `password:` is the password the people it creates sign in with (default: the fixed local
  development one). A person who already exists keeps the password they have: a re-run
  never resets one.
  """
  @spec run!(keyword()) :: %{
          organization: Organization.t(),
          counts: map(),
          clinic: map(),
          mdm: map() | nil
        }
  def run!(opts \\ []) do
    organization = provision!(opts)
    Map.put(populate!(organization, opts), :organization, organization)
  end
end
