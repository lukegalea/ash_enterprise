defmodule Mix.Tasks.AshEnterprise.Integration.Tag do
  @shortdoc "Sets a linked account's zone tags: data class and residency (ADR 0042)"

  @moduledoc """
  Declares the zone tags of everything synced through one linked account
  (ADR 0042): its data class and its residency restriction. Zone admission
  (`AshEnterprise.Canonical.Projections.ZoneAdmission`) admits a landed record
  into the canonical store on these tags; an untagged account's records are
  refused.

      mix ash_enterprise.integration.tag --email you@example.com \\
        --linked-account <id> --data-class internal --residency CA

  * `--data-class` is one of `public`, `synthetic`, `internal`,
    `customer_confidential`, `personal_finance`
    (`AshEnterprise.Zones.Types.DataClass`). A Tiller sheet is
    `personal_finance`: the finance sync admits it into the finance zone
    (`AshEnterprise.Finance`) on these same tags, at land.
  * `--residency` is `unrestricted` or the ISO 3166 code the data is
    restricted to (`CA`, `CA-ON`, `US`).
  * Pass `--clear` instead to untag the account (both nil), which refuses its
    records from the next projection on.

  The tags are the operator's statement about the account, never inferred from
  its content. Set as the user named by `--email`, under their own grants
  (`write` on their `AshEnterprise.Integration.LinkedAccount`), and audited
  like any other update. Already-projected rows are not withdrawn by a re-tag:
  shred the account's scope for that (`docs/runbooks/crypto-shredding.md`).
  """

  use Mix.Task

  alias AshEnterprise.Integration.{Console, LinkedAccount}
  alias AshEnterprise.Mix.Helpers
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Zones.Types.DataClass

  @requirements ["app.config"]

  @switches [
    email: :string,
    linked_account: :string,
    data_class: :string,
    residency: :string,
    clear: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _args, _invalid} = OptionParser.parse(argv, strict: @switches)

    email = opts[:email] || Mix.raise("--email <user> is required")
    id = opts[:linked_account] || Mix.raise("--linked-account <id> is required")
    tags = tags!(opts)

    # Repo only: no Oban, no endpoint (iron law #23).
    Helpers.boot_repo()

    actor = actor!(email)
    tenant = ActorContext.tenant(actor)

    actor
    |> account!(tenant, email, id)
    |> LinkedAccount.tag_for_zone(tags, actor: actor, tenant: tenant)
    |> report(email, id)
  end

  defp actor!(email) do
    case Console.actor_for_email(email) do
      {:ok, actor} -> actor
      {:error, :no_such_user} -> Mix.raise("no user with email #{email}")
    end
  end

  defp account!(actor, tenant, email, id) do
    case LinkedAccount.mine(nil, %{}, actor: actor, tenant: tenant) do
      {:ok, accounts} -> Enum.find(accounts, &(&1.id == id))
      {:error, _error} -> nil
    end || Mix.raise("#{email} has no linked account #{id}")
  end

  defp report({:ok, account}, _email, _id) do
    Mix.shell().info(
      "Tagged #{account.provider_config_key} account #{account.id}: " <>
        "data_class=#{account.data_class || "-"} residency=#{account.residency || "-"}"
    )
  end

  defp report({:error, %Ash.Error.Forbidden{}}, email, id),
    do: Mix.raise("#{email} may not tag linked account #{id}")

  defp report({:error, error}, _email, _id) do
    # Field names and messages only.
    fields =
      error
      |> Ash.Error.to_error_class()
      |> Map.get(:errors, [])
      |> Enum.map_join(", ", &"#{Map.get(&1, :field) || "tag"}: #{Map.get(&1, :message)}")

    Mix.raise("tag refused: #{fields}")
  end

  defp tags!(opts) do
    if opts[:clear] do
      %{data_class: nil, residency: nil}
    else
      %{
        data_class: data_class!(opts[:data_class]),
        residency: opts[:residency] || Mix.raise("--residency (or --clear) is required")
      }
    end
  end

  defp data_class!(value) when is_binary(value) do
    case DataClass.match(value) do
      {:ok, class} -> class
      :error -> Mix.raise("--data-class must be one of #{inspect(DataClass.values())}")
    end
  end

  defp data_class!(_), do: Mix.raise("--data-class (or --clear) is required")
end
