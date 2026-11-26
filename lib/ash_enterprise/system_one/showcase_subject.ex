defmodule AshEnterprise.SystemOne.ShowcaseSubject do
  @moduledoc """
  The declaration the showcase's three-valued search beat
  (`AshEnterprise.Showcase.Search`) searches over: one synthetic clinic
  question, with nothing stored. The subjects are the beat's own invented
  clinicians; their facts are admitted through the materialiser like any
  other (`AshEnterprise.Showcase.Search.seed!/2`).

  Declared in `config :ash_enterprise, :system_one_subject_resources`, so the
  filter vocabulary (`AshEnterprise.SystemOne.Filter.Queryables`) carries it.
  Its hash is locked in `priv/judgments/lock.json`.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.SystemOne,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    policies?: false,
    extra_extensions: [AshAi, AshJudgments.Registry]

  resource do
    require_primary_key? false
  end

  attributes do
    attribute :id, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  judgments do
    question :licence_scan_legible do
      type AshAi.Evaluate.Noul
      instructions("Is the scan of the clinician's licence certificate legible?")

      criteria(%{
        false:
          "The scan cannot be read: cropped, blurred or too dark to make out the licence number.",
        true: "The scan can be read: the licence number and the dates are clear."
      })

      version(1)
      family(:showcase_search)
      profile(:winnow_gpu)
    end
  end
end
