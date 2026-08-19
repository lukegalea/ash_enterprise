defmodule Mix.Tasks.AshEnterprise.Bpmn.Publish do
  @shortdoc "Publish the baseline processes and decisions into the platform organization"

  @moduledoc """
  Publishes every artifact in `priv/dmn/` and `priv/bpmn/` as a baseline.

  ## Baselines are code, not UI

  Publishing into the platform organization is deliberately impossible from the web. A baseline
  applies to every tenant that has not diverged, so changing one is a deployment act and the
  artifacts are reviewed files in the repository — the same arrangement `priv/legacy/schema.sql`
  has, applied by `mix ash_enterprise.legacy.setup`.

  A tenant customizing a process authors it in the designer, in its own tenant, and rebinds.
  That path goes through the UI precisely because it affects only them.

  ## Idempotent, by content hash

  Re-running publishes nothing whose XML is already published. That matters because this runs
  on every deploy: without it, each deploy would mint a new version of every baseline and every
  tenant tracking one would silently jump versions for no reason.

  ## Decisions first

  A `businessRuleTask` is verified at publish time against the decision it names, so a process
  referencing an unpublished decision is refused — correctly, and confusingly if the order is
  wrong. Decisions are published first for that reason and not by preference.

      mix ash_enterprise.bpmn.publish
  """

  use Mix.Task

  require Ash.Query

  alias AshEnterprise.Bpmn
  alias AshEnterprise.Decisions
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Process.Resolver

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.start")

    organization = Seeder.seed_platform_organization()
    Mix.shell().info("platform organization: #{organization.id}")

    # Decisions before processes: see the moduledoc.
    published =
      publish_all("priv/dmn/*.dmn", Decisions.Definition, organization.id) ++
        publish_all("priv/bpmn/*.bpmn", Bpmn.Definition, organization.id)

    Resolver.forget_platform_tenant()

    Mix.shell().info("\n#{length(published)} artifact(s) considered:")
    Enum.each(published, fn {key, status} -> Mix.shell().info("  #{status}  #{key}") end)
  end

  defp publish_all(glob, resource, tenant) do
    glob
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&publish(&1, resource, tenant))
  end

  defp publish(path, resource, tenant) do
    key = key_for(path)
    xml = File.read!(path)
    hash = :sha256 |> :crypto.hash(xml) |> Base.encode16(case: :lower)

    if already_published?(resource, key, hash, tenant) do
      {key, "unchanged"}
    else
      do_publish(resource, key, xml, tenant)
    end
  end

  # The artifact's filename is its key, with the **last** underscore becoming the dot that
  # separates the subject from the thing being done to it:
  #
  #     access_request_risk.dmn   -> access_request.risk
  #     access_request_grant.bpmn -> access_request.grant
  #
  # The first underscore is the tempting one and it is wrong -- it yields `access.request_risk`,
  # which then fails to match the `ash:decision ref` in the process and produces a
  # publish-time refusal several steps away from the cause.
  defp key_for(path) do
    path
    |> Path.basename()
    |> Path.rootname()
    |> String.split("_")
    |> case do
      [single] -> single
      parts -> Enum.join(Enum.drop(parts, -1), "_") <> "." <> List.last(parts)
    end
  end

  defp already_published?(resource, key, hash, tenant) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(key == ^key and content_hash == ^hash and status == :published)
    |> Ash.Query.limit(1)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
    |> Enum.any?()
  end

  defp do_publish(resource, key, xml, tenant) do
    opts = [actor: SystemActor.process(), tenant: tenant]

    definition = resource.create!(%{key: key, name: humanize(key), xml: xml}, opts)

    case definition.errors do
      errors when errors in [nil, []] ->
        resource.publish!(definition, opts)
        {key, "published v#{definition.version}"}

      errors ->
        # Refusing to publish a broken artifact is the point of compiling at write time. The
        # errors name the element, so print them rather than a summary.
        Mix.shell().error("\n#{key} did not compile:")
        Enum.each(errors, fn e -> Mix.shell().error("  [#{e["path"]}] #{e["message"]}") end)
        Mix.raise("#{key} could not be published")
    end
  end

  defp humanize(key) do
    key |> String.replace(~r/[._]/, " ") |> String.capitalize()
  end
end
