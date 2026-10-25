defmodule Battery.SystemOne.CaseFileProjection do
  @moduledoc """
  The evidence question's state projection: the instrument sees the parsed
  text and the atom ids the evidence parse produced — and nothing else.
  """

  @behaviour AshJudgments.Registry.StateProjection

  @impl true
  def project(input, _context),
    do: %{"text" => input.arguments.input["text"], "atom_ids" => input.arguments.input["atom_ids"]}
end

defmodule Battery.SystemOne.CaseFile do
  @moduledoc """
  A judged subject: a document case file carrying one System One
  EVIDENCE question ("does the parsed document support the predicate?").
  The question's answer type is `AshJudgments.Evaluate.Evidence` — the
  frozen disposition + distribution + confidence + CITED ATOM IDS, which
  is exactly the seam with ash_evidence: the atoms the evidence parse run
  addressed are the ids the judged answer cites.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAi, AshJudgments.Registry]

  judgments do
    question :evidence_support do
      type AshJudgments.Evaluate.Evidence
      instructions("Does the document support the stated predicate?")
      version(1)
      family(:case_review)
      profile(:test_local)
      pii(:minimised)
      state_projection(Battery.SystemOne.CaseFileProjection)
      ttl(3600)
    end
  end

  postgres do
    table "battery_case_files"
    repo(Battery.Repo)
  end

  actions do
    defaults [:read]

    create :create do
      accept [:reference]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :reference, :string do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
  end
end
