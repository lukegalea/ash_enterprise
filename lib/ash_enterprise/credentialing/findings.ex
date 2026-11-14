defmodule AshEnterprise.Credentialing.Findings do
  @moduledoc """
  What the licence reader found in a credential's documents, as the reader may see it:
  each finding (`AshEnterprise.SystemOne.Judgment`, written by
  `LicenceDocument.record_finding`) with the document it is about, the question, its
  status and typed value, and the lines it cites, resolved from the evidence store by
  their atoms' ids.

  The credential's own detail shows them (`Credential.document_findings`), and so does
  the showcase tour.

  ## A finding that copies a secured column

  The licence number a document states is the credential's number, which is a secured
  column (`Credential`'s `secured_fields`, ADR 0073): a row grant on credentials does not
  show it. A finding that answers the licence number question is that value copied, and so
  is the line it cites. So for a reader who cannot read the credential's `number`, read
  through the reader in one query per call, the finding's value and its lines' text are
  `%Ash.ForbiddenField{}`, which a page shows as hidden. Its status, its document and its
  line numbers stay: the reader may know a number was found, and where, without reading
  it.
  """

  require Ash.Query

  alias AshEnterprise.Credentialing.Actions.RecordLicenceFinding
  alias AshEnterprise.Credentialing.Credential
  alias AshEnterprise.SystemOne.Judgment

  # The questions whose answer is a copy of a secured column of the document's credential.
  @secured_questions %{"licence_number" => :number}

  @type finding :: %{
          judgment: struct(),
          document: struct(),
          question: String.t(),
          status: String.t(),
          value: String.t() | Ash.ForbiddenField.t() | nil,
          lines: [%{line: integer(), text: String.t() | Ash.ForbiddenField.t()}]
        }

  @doc """
  The findings about `documents` that `opts` (actor and tenant) may read, newest first.
  `run_ids` narrows them to the runs that wrote them.
  """
  @spec for_documents([struct()], keyword(), [String.t()] | nil) :: [finding()]
  def for_documents(documents, opts, run_ids \\ nil)
  def for_documents([], _opts, _run_ids), do: []

  def for_documents(documents, opts, run_ids) do
    by_id = Map.new(documents, &{to_string(&1.id), &1})
    ids = Map.keys(by_id)
    type = RecordLicenceFinding.subject_type()

    judgments =
      Judgment
      |> Ash.Query.filter(subject_type == ^type and subject_id in ^ids)
      |> narrow(run_ids)
      |> Ash.Query.sort(recorded_at: :desc)
      |> Ash.read!(opts)

    lines = lines(judgments)
    visible = visible_columns(judgments, by_id, opts)

    Enum.map(judgments, fn judgment ->
      document = Map.fetch!(by_id, judgment.subject_id)
      question = question(judgment.question_id)

      %{
        judgment: judgment,
        document: document,
        question: question,
        status: (judgment.state_ref || %{})["status"] || status(judgment),
        value: value(judgment.value),
        lines: Enum.flat_map(judgment.atom_ids || [], &List.wrap(Map.get(lines, &1)))
      }
      |> mask(Map.get(@secured_questions, question), document, visible)
    end)
  end

  # The `{credential id, column}` pairs the reader may read, for the credentials whose
  # findings copy a secured column. Read through the reader, so the field policy decides;
  # a credential the read does not return shows none.
  defp visible_columns(judgments, by_id, opts) do
    columns =
      judgments
      |> Enum.map(&Map.get(@secured_questions, question(&1.question_id)))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    ids =
      judgments
      |> Enum.map(&Map.fetch!(by_id, &1.subject_id).credential_id)
      |> Enum.uniq()

    if columns == [] or ids == [] do
      MapSet.new()
    else
      for credential <-
            Credential
            |> Ash.Query.filter(id in ^ids)
            |> Ash.Query.select(columns)
            |> Ash.read!(opts),
          column <- columns,
          not match?(%Ash.ForbiddenField{}, Map.get(credential, column)),
          into: MapSet.new(),
          do: {credential.id, column}
    end
  end

  defp mask(finding, nil, _document, _visible), do: finding

  defp mask(finding, column, document, visible) do
    if MapSet.member?(visible, {document.credential_id, column}) do
      finding
    else
      hidden = %Ash.ForbiddenField{field: column, type: :attribute}

      %{
        finding
        | value: if(finding.value, do: hidden),
          lines: Enum.map(finding.lines, &%{&1 | text: hidden})
      }
    end
  end

  @doc """
  One line per finding: `Licence number: DEMO-PT-0001 (found; certificate, line 5)`, with
  `hidden` for a value the reader may not read.
  """
  @spec summary([finding()]) :: String.t() | nil
  def summary([]), do: nil

  def summary(findings) do
    Enum.map_join(findings, " · ", fn finding ->
      lines = Enum.map_join(finding.lines, ", ", &to_string(&1.line))

      "#{label(finding.question)}: #{text(finding.value)} " <>
        "(#{finding.status}; #{finding.document.title}, line #{lines})"
    end)
  end

  defp text(nil), do: "—"
  defp text(%Ash.ForbiddenField{}), do: "hidden"
  defp text(value), do: value

  # The ledger keeps a string extraction as itself and any other value as its JSON text
  # (a date is `"\"2028-06-30\""`).
  defp value(nil), do: nil

  defp value(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_binary(decoded) -> decoded
      _string -> value
    end
  end

  defp narrow(query, nil), do: query
  defp narrow(query, run_ids), do: Ash.Query.filter(query, run_id in ^run_ids)

  defp lines([]), do: %{}

  defp lines(judgments) do
    judgments
    |> Enum.flat_map(&(&1.atom_ids || []))
    |> Enum.uniq()
    |> AshEvidence.Domain.atoms_by_ids!()
    |> Map.new(&{to_string(&1.id), %{line: &1.seq, text: &1.text}})
  end

  # `judgment:v0:<Resource>#judgments/<name>`.
  defp question(question_id), do: question_id |> String.split("/") |> List.last()

  defp status(%{value: nil}), do: "not_found"
  defp status(_judgment), do: "found"

  defp label("licence_number"), do: "Licence number"
  defp label("licence_valid_until"), do: "Valid until"
  defp label(other), do: other
end
