defmodule AshEnterprise.Credentialing.Actions.RecordLicenceFinding do
  @moduledoc """
  `LicenceDocument.record_finding`: one answer to one of the document's declared
  questions, recorded as a judgment in the `ash_judgments` ledger
  (`AshEnterprise.SystemOne.Judgment`) through the package's own recorder
  (`AshJudgments.Ledger.Record`), the seam every judged answer takes.

  What the row holds:

    * the question's identity (`question_id`, `question_hash`, version, family);
    * the subject, the document (`licence_document`, its id);
    * the answer, cast by the question's declared type
      (`AshJudgments.Evaluate.Extraction`): its typed value (none unless found) and the
      cited lines as their atoms' ids, the source references. The ledger keeps no status
      of its own (a value is there only when found), so the status rides `state_ref`
      beside the document version it was read from;
    * the model as requested (the run's, `AshEnterprise.Execution.AgentRuntime.model_label/1`);
    * the lineage: the run, the step, the tool call and the invocation that wrote it,
      read from the invocation the call runs as (`context.ash_agent`);
    * the cited lines' text, sealed under the clinician's erasure scope
      (`AshEnterprise.SystemOne.Changes.SealJudgedState`), so erasing the clinician
      erases the text a finding quotes and leaves its digests.

  The document is read as the caller first. A line that is not in the document, or an
  answer the question's type does not cast (a value when nothing was found, a date that
  is not one), is refused and nothing is recorded.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Credentialing.Actions.ReadLicenceText
  alias AshEnterprise.Credentialing.{LicenceDocument, LicenceReader}
  alias AshEnterprise.Execution.AgentRuntime
  alias AshEnterprise.SystemOne
  alias AshJudgments.Evaluate.Extraction

  @subject_type "licence_document"

  @doc "The ledger's subject type for a licence document."
  @spec subject_type() :: String.t()
  def subject_type, do: @subject_type

  @impl true
  def run(input, _opts, context) do
    args = input.arguments
    question = AshJudgments.Registry.Info.question(LicenceDocument, args.question)

    with {:ok, document} <-
           ReadLicenceText.document(args.number, args.kind, Ash.Context.to_opts(context)),
         atoms = ReadLicenceText.atoms(document),
         {:ok, cited} <- cited(atoms, args.lines),
         {:ok, answer} <- answer(args, atoms, cited, question),
         {:ok, judgment} <- record(question, answer, document, cited, input) do
      {:ok,
       %{
         "judgment" => judgment.id,
         "question" => to_string(args.question),
         "status" => to_string(answer.status),
         "value" => answer.value && to_string(answer.value),
         "lines" => args.lines
       }}
    end
  end

  defp cited(atoms, lines) do
    by_line = Map.new(atoms, &{&1.seq, &1})

    case Enum.reject(lines, &Map.has_key?(by_line, &1)) do
      [] -> {:ok, Enum.map(Enum.uniq(lines), &Map.fetch!(by_line, &1))}
      missing -> {:error, "lines #{Enum.join(missing, ", ")} are not in the document"}
    end
  end

  # Cast by the question's declared type, with the packet narrowed to this document's
  # atoms: a finding cites the document it is about.
  defp answer(args, atoms, cited, question) do
    Extraction.from_answer(
      %{
        "status" => to_string(args.status),
        "value" => args[:value],
        "source_ids" => Enum.map(cited, &to_string(&1.id))
      },
      question.constraints
      |> Map.new()
      |> Map.put(:source_enum, Enum.map(atoms, &to_string(&1.id)))
    )
  end

  defp record(question, answer, document, cited, input) do
    state = %{
      "document" => document.title,
      "lines" => Enum.map(cited, &%{"line" => &1.seq, "text" => &1.text})
    }

    judge_context =
      SystemOne.judge_context(
        tenant: input.tenant,
        lineage: lineage(input.context),
        judgments: %{
          subject: %{type: @subject_type, id: document.id},
          model_spec: AgentRuntime.model_label(LicenceReader.key()),
          state_ref: %{
            "document_version_id" => document.document_version_id,
            "status" => to_string(answer.status)
          }
        },
        judged_state: state,
        judged_state_scope_id: document.credential.clinician.erasure_scope_id
      )

    AshJudgments.Ledger.Record.record(
      question,
      answer,
      judge_context,
      %{state: state},
      judge_context
    )
  end

  # The invocation the call runs as names the run, its step and the tool call:
  # `run:<run id>:<step seq>:<tool call id>`.
  defp lineage(%{ash_agent: ash_agent}), do: lineage(ash_agent)

  defp lineage(%{invocation_id: id, invocation_key: "run:" <> rest}) do
    case String.split(rest, ":", parts: 3) do
      [run_id, step, call] ->
        %{run_id: run_id, step_id: step, tool_call_id: call, invocation_id: id}

      _other ->
        %{invocation_id: id}
    end
  end

  defp lineage(%{invocation_id: id}), do: %{invocation_id: id}
  defp lineage(_none), do: nil
end
