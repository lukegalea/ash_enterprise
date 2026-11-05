defmodule AshEnterprise.Credentialing.CaseProcess do
  @moduledoc """
  The credentialing case as a BPMN process (`priv/showcase/credentialing_case.bpmn`,
  key `"credentialing.case"`), for the showcase's third slice.

  ## What the diagram does

    * the evidence checks (`Credential.check_documents`, `Credential.check_expiry`) run in
      parallel, as service tasks through their invocations, as the person who opened the
      case;
    * a check the business refuses is caught by its error boundary, and the other check
      carries on: a missing licence document is asked for (`Credential.request_documents`)
      and awaited on a receive task correlated on the credential, which the "document
      received" webhook wakes (`AshEnterprise.Credentialing.DocumentWebhook`), once;
    * a parallel join waits for both branches, then the credentialing committee decides on
      a user task (approve or reject, a different person from the one who owns the
      credential);
    * an approved case waits on a timer for its re-credentialing date (`recredential_node/0`,
      `P365D`), which is a durable job, not a process in memory.

  ## Where it is published

  Into the tenant that uses it (`publish!/1`), never the platform baselines: it is a worked
  example, and `mix ash_enterprise.bpmn.publish` does not read `priv/showcase/`. Publishing
  is by content: a tenant whose latest published version has the file's XML gets nothing
  new, so refreshing the demo is a no-op.
  """

  require Ash.Query

  alias AshEnterprise.Bpmn.{Definition, Instance}
  alias AshEnterprise.Platform.SystemActor

  @key "credentialing.case"
  @recredential "Recredential"
  @committee "CommitteeReview"
  @await "AwaitDocument"

  @doc "The definition's key."
  @spec key() :: String.t()
  def key, do: @key

  @doc "The node id of the committee's review."
  @spec committee_node() :: String.t()
  def committee_node, do: @committee

  @doc "The node id of the wait for the document."
  @spec await_node() :: String.t()
  def await_node, do: @await

  @doc "The node id of the re-credentialing timer."
  @spec recredential_node() :: String.t()
  def recredential_node, do: @recredential

  # Sobelow reads `@sobelow_skip` out of the source AST; persisting it keeps
  # `--warnings-as-errors` from calling it unused (see AshEnterprise.Mdm.Baselines).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  # The path is a constant under this application's own priv dir: no caller input reaches it.
  @doc "The checked-in diagram's XML."
  @spec xml() :: String.t()
  @sobelow_skip ["Traversal.FileModule"]
  def xml,
    do: File.read!(Path.join(:code.priv_dir(:ash_enterprise), "showcase/credentialing_case.bpmn"))

  @doc """
  Publishes the diagram into `tenant` when its latest published version differs from the
  file (or there is none). `:unchanged` or `{:published, version}`.
  """
  @spec publish!(Ash.UUID.t()) :: :unchanged | {:published, pos_integer()}
  def publish!(tenant) do
    xml = xml()
    opts = [actor: SystemActor.process(), tenant: tenant]

    case latest(tenant) do
      %{xml: published} when published != nil ->
        if String.trim(published) == String.trim(xml), do: :unchanged, else: create!(xml, opts)

      _none ->
        create!(xml, opts)
    end
  end

  defp create!(xml, opts) do
    published =
      %{key: @key, name: "Credentialing case", xml: xml}
      |> Definition.create!(opts)
      |> Definition.publish!(opts)

    {:published, published.version}
  end

  defp latest(tenant) do
    Definition
    |> Ash.Query.filter(key == ^@key and status == :published)
    |> Ash.Query.sort(version: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(actor: SystemActor.process(), tenant: tenant)
  end

  @doc "The latest published definition in `tenant`: `{:ok, definition}` or `{:error, :case_not_published}`."
  @spec definition(Ash.UUID.t()) :: {:ok, struct()} | {:error, :case_not_published}
  def definition(tenant) do
    case latest(tenant) do
      nil -> {:error, :case_not_published}
      definition -> {:ok, definition}
    end
  end

  @doc "The running case of the credential `credential_id`, or `nil`."
  @spec running(Ash.UUID.t(), Ash.UUID.t()) :: struct() | nil
  def running(credential_id, tenant) do
    subject_type = to_string(AshEnterprise.Credentialing.Credential)

    Instance
    |> Ash.Query.filter(
      subject_id == ^credential_id and status == :running and subject_type == ^subject_type
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one!(actor: SystemActor.process(), tenant: tenant)
  end
end
