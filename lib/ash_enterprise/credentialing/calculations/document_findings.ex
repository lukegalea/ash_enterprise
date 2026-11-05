defmodule AshEnterprise.Credentialing.Calculations.DocumentFindings do
  @moduledoc """
  `Credential.document_findings`: what the licence reader found in the credential's
  documents, one line per finding with the lines it cites
  (`AshEnterprise.Credentialing.Findings.summary/1`), as the reader may see them.
  `nil` when nothing was found yet.
  """

  use Ash.Resource.Calculation

  alias AshEnterprise.Credentialing.Findings

  @impl true
  def load(_query, _opts, _context), do: [licence_documents: [:id, :kind, :title, :credential_id]]

  @impl true
  def calculate(credentials, _opts, context) do
    opts = [actor: context.actor, tenant: context.tenant, authorize?: context.authorize?]
    documents = Enum.flat_map(credentials, &List.wrap(&1.licence_documents))
    findings = Findings.for_documents(documents, opts)
    by_credential = Enum.group_by(findings, & &1.document.credential_id)

    Enum.map(credentials, fn credential ->
      by_credential |> Map.get(credential.id, []) |> latest() |> Findings.summary()
    end)
  end

  # The newest finding per document and question.
  defp latest(findings), do: Enum.uniq_by(findings, &{&1.document.id, &1.question})
end
