defmodule AshEnterpriseWeb.Bpmn.Baselines do
  @moduledoc """
  The designer's and the decision editor's view of platform baselines.

  `ash_bpmn` and `ash_decisions` know nothing about the platform organization -- that is host
  policy, and it lives in `AshEnterprise.Process.Resolver`. What the editors need is two
  questions answered for a key the tenant has stored nothing for:

    * **What would this tenant run?** (`:baseline`) -- the resolver's answer, if it is a
      platform definition. The editor shows it read-only.
    * **Make it ours.** (`:customize`) -- `Resolver.fork/4`, the same call the catalogue's
      Customize button makes, so lineage is recorded the same way whichever screen it starts
      from.

  Before these existed, opening an editor on a baseline key created a draft from a blank
  starter template over the baseline: the tenant saw an empty canvas, and the catalogue showed
  a "customization" nobody had made.

  Each function takes the socket last, per the libraries' MFA convention.
  """

  alias AshEnterprise.Process.Resolver

  @doc "The platform process `key` resolves to for this tenant, or nil."
  def process_baseline(key, socket), do: baseline(:process, key, socket)

  @doc "The platform decision `key` resolves to for this tenant, or nil."
  def decision_baseline(key, socket), do: baseline(:decision, key, socket)

  @doc "Forks the process baseline into the tenant's own draft."
  def customize_process(key, socket), do: customize(:process, key, socket)

  @doc "Forks the decision baseline into the tenant's own draft."
  def customize_decision(key, socket), do: customize(:decision, key, socket)

  # Only a platform row counts. The editors ask this only when the tenant has neither a draft
  # nor a published definition of its own, but the resolver would hand back a tenant row for a
  # `source: :tenant` binding -- and that is not a baseline, whatever else it is.
  defp baseline(kind, key, socket) do
    with tenant when not is_nil(tenant) <- socket.assigns[:current_tenant],
         platform when not is_nil(platform) <- Resolver.platform_tenant(),
         {:ok, %{organization_id: ^platform} = definition} <-
           Resolver.resolve(kind, key, tenant) do
      definition
    else
      _ -> nil
    end
  end

  # The actor is the signed-in administrator, not a system actor: forking is a person's
  # decision and the audit entry should name them.
  defp customize(kind, key, socket) do
    case Resolver.fork(kind, key, socket.assigns[:current_tenant], socket.assigns[:current_user]) do
      {:ok, draft} -> {:ok, draft}
      {:error, error} -> {:error, fork_error(error)}
    end
  end

  @doc """
  What to tell a person whose fork failed.

  `Resolver.fork/4` fails with bare atoms and tuples, not exceptions -- calling
  `Exception.message/1` on them is a FunctionClauseError waiting for the first failed fork. One
  clause per shape the resolver can return, and deliberately no catch-all: if the union grows,
  dialyzer names the shape that has no copy yet.
  """
  def fork_error(:no_platform_organization),
    do:
      "The platform organization is missing, so there is no baseline to customize from. Run mix ash_enterprise.seed."

  def fork_error({:no_platform_organization, _detail}),
    do: fork_error(:no_platform_organization)

  def fork_error({:definition_not_found, kind, key}),
    do: "There is no #{kind} named \"#{key}\" to customize."

  def fork_error({:no_published_baseline, kind, key}),
    do: "\"#{key}\" has no published #{kind} baseline to customize from yet."
end
