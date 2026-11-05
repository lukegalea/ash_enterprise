defmodule AshEnterprise.Credentialing.Actions.ReadLicenceText do
  @moduledoc """
  `LicenceDocument.read_text`: the lines of one of a credential's documents, numbered as
  their atoms are (`AshEvidence.AddressedAtom.seq`):

      %{"document" => title, "kind" => "certificate", "lines" => [%{"line" => 1, "text" => ...}]}

  The document is found by the credential's number and the document's kind, read as the
  caller, so the action answers only about a document the caller may read.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias AshEnterprise.Credentialing.LicenceDocument

  @impl true
  def run(input, _opts, context) do
    %{number: number, kind: kind} = input.arguments

    with {:ok, document} <- document(number, kind, Ash.Context.to_opts(context)) do
      {:ok,
       %{
         "document" => document.title,
         "kind" => to_string(document.kind),
         "lines" => Enum.map(atoms(document), &%{"line" => &1.seq, "text" => &1.text})
       }}
    end
  end

  @doc """
  The `kind` document of the credential numbered `number`, with its credential and
  clinician, read with `opts`.
  """
  @spec document(String.t(), atom(), keyword()) :: {:ok, struct()} | {:error, term()}
  def document(number, kind, opts) do
    LicenceDocument
    |> Ash.Query.filter(kind == ^kind and credential.number == ^number)
    |> Ash.Query.load(credential: :clinician)
    |> Ash.read_one(opts)
    |> case do
      {:ok, nil} ->
        {:error,
         Ash.Error.Query.NotFound.exception(
           resource: LicenceDocument,
           primary_key: %{number: number, kind: kind}
         )}

      other ->
        other
    end
  end

  @doc "The document's lines (its version's atoms), in order."
  @spec atoms(struct()) :: [struct()]
  def atoms(document), do: AshEvidence.Domain.atoms_for_version!(document.document_version_id)
end
