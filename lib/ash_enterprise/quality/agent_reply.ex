defmodule AshEnterprise.Quality.AgentReply do
  @moduledoc """
  One assistant answer, as the subject the agent-quality judgment families
  grade (S1-91; `research/s1-79-agent-quality-via-judgments.md` in the
  programme repo, ADR 0058 and its 2026-10-31 amendment).

  ## Where a reply comes from

  The `:from_turn` read takes the id of an answer
  (`AshEnterprise.Assistant.Turn`, role `:assistant`) and reads that turn
  as the actor, in the query's tenant. The turn's `content` is sealed under
  its thread's erasure scope, so the text is decrypted only for an actor the
  turn's own policies let read it: the person whose thread it is, or a
  system actor. Anyone else, and a turn that is a question, read as no
  reply. A turn whose scope is shredded has no text left to judge and also
  reads as no reply.

  Nothing is stored (`Ash.DataLayer.Simple`), so there is nothing to audit,
  archive, emit lineage for or hold per tenant: `audit?: false`,
  `archival?: false`, `lineage?: false`, `tenant?: false` and
  `ownership: :none`. Facts about a reply live in
  `AshEnterprise.SystemOne.Fact`, keyed by
  `AshEnterprise.Quality.subject_term/1`. Authorization of the read itself
  is the platform's standard set.

  ## Subject identity

    * `"assistant_turn:<turn_id>"` for a turn graded on its own;
    * `"agent_reply:<run_id>/<case_id>/<epoch>"` when `run_id`, `case_id`
      and `epoch` are given (an evaluation run's case). A re-run of a case
      is a new epoch, so a new subject, and never overwrites the verdicts on
      an earlier one.

  `text` is normalised (`AshEnterprise.Quality.normalise_text/1`), and the
  reply's digest (`AshEnterprise.Quality.digest/1`) is the digest of what
  `AshEnterprise.Quality.Projections.ReplyText` shows the model. Turns are
  append-only, so a reply's digest never changes under its facts.

  `erasure_scope_id` is the turn's scope, so the text a judge reads can be
  sealed under it (`AshEnterprise.SystemOne.JudgedState`): shredding the
  thread shreds the judged text too.

  `used_tools` is true when the turn's `refs` or `tool_calls` are not
  empty. `AshEnterprise.Quality.Questions` reads it: hs4 and hs7 are not
  asked of a reply that used tools.

  ## The questions

  The eight `agent_reply_style` questions below are the house-style
  questions hs1 to hs8 declared on `AshEnterprise.Standards.CodeUnit`, with
  "the document" read as "the reply" and nothing else changed, on a new
  resource with a new projection and shape, at version 1, in a new family.
  The family is new because the `house_style` band table was certified on
  code and documentation units; a certification is evidence about the text
  it measured, not about chat replies. Until a reply calibration set is
  labelled and a band table for this family certified and published, the
  family admits nothing and every reply reads `unknown`.

  The hashes are locked in `priv/judgments/lock.json`, so a wording or
  shape change is a compile error until it arrives with a version bump.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Quality,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    audit?: false,
    archival?: false,
    lineage?: false,
    extra_extensions: [AshAi, AshJudgments.Registry]

  attributes do
    attribute :id, :string,
      primary_key?: true,
      allow_nil?: false,
      public?: true,
      description:
        ~s(The subject id: "assistant_turn:<turn_id>" or "agent_reply:<run_id>/<case_id>/<epoch>".)

    attribute :text, :string,
      allow_nil?: false,
      public?: true,
      constraints: [trim?: false, allow_empty?: true],
      description: "The reply text, normalised. Decrypted from the turn as the actor."

    attribute :turn_id, :uuid, allow_nil?: false, public?: true
    attribute :thread_id, :uuid, allow_nil?: false, public?: true

    attribute :erasure_scope_id, :uuid,
      allow_nil?: false,
      public?: true,
      description: "The turn's erasure scope, which the judged text is sealed under."

    attribute :status, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:complete, :stopped, :failed]],
      description: "How the run that wrote the answer ended."

    attribute :used_tools, :boolean,
      allow_nil?: false,
      public?: true,
      default: false,
      description: "True when the answer's run called a tool or cited a record a tool returned."
  end

  actions do
    defaults [:read]

    read :from_turn do
      description """
      One answer turn as a reply subject, read as the actor (nothing is
      stored). Give `run_id`, `case_id` and `epoch` together to name the
      subject by an evaluation run's case.
      """

      get? true

      argument :turn_id, :uuid, allow_nil?: false
      argument :run_id, :string
      argument :case_id, :string
      argument :epoch, :integer, constraints: [min: 0]

      manual AshEnterprise.Quality.AgentReply.FromTurn
    end
  end

  judgments do
    question :hs1_lead_with_outcome_or_ask do
      # judgment:v0:AshEnterprise.Quality.AgentReply#judgments/hs1_lead_with_outcome_or_ask
      type AshAi.Evaluate.Noul

      instructions(
        "Check if the reply's first sentence follows the 'Lead with the outcome or the ask' standard."
      )

      criteria(%{
        false:
          "The first sentence of the reply does not state what happened, what the reader must decide, or what the thing does.",
        true:
          "The first sentence of the reply states what happened, what the reader must decide, or what the thing does."
      })

      version(1)
      family(:agent_reply_style)
      profile(:winnow_gpu)
      state_projection(AshEnterprise.Quality.Projections.ReplyText)
      state_shape(AshEnterprise.Quality.Projections.ReplyText.shape())
    end

    question :hs2_keep_it_short do
      # judgment:v0:AshEnterprise.Quality.AgentReply#judgments/hs2_keep_it_short
      type AshAi.Evaluate.Noul

      instructions(
        "Check if the reply adheres to the 'Keep it short' standard regarding paragraph length and list formatting."
      )

      criteria(%{
        false:
          "The reply contains paragraphs that are not short or lists of more than three items that are not presented as a table or a list.",
        true:
          "The reply uses short paragraphs and presents items as a table or a list when there are more than three of anything."
      })

      version(1)
      family(:agent_reply_style)
      profile(:winnow_gpu)
      state_projection(AshEnterprise.Quality.Projections.ReplyText)
      state_shape(AshEnterprise.Quality.Projections.ReplyText.shape())
    end

    question :hs3_use_plain_words do
      # judgment:v0:AshEnterprise.Quality.AgentReply#judgments/hs3_use_plain_words
      type AshAi.Evaluate.Noul
      instructions("Check if the reply adheres to the 'Use plain words' standard.")

      criteria(%{
        false:
          "The reply uses complex phrasing, filler openers, repeated apologies, or exclamation marks.",
        true:
          "The reply uses plain words, avoids filler openers, apologises at most once, and contains no exclamation marks."
      })

      version(1)
      family(:agent_reply_style)
      profile(:winnow_gpu)
      state_projection(AshEnterprise.Quality.Projections.ReplyText)
      state_shape(AshEnterprise.Quality.Projections.ReplyText.shape())
    end

    question :hs4_claim_only_built_and_proven do
      # judgment:v0:AshEnterprise.Quality.AgentReply#judgments/hs4_claim_only_built_and_proven
      type AshAi.Evaluate.Noul

      instructions(
        "Check if the reply adheres to the 'Claim only what is built and proven' standard."
      )

      criteria(%{
        false:
          "The reply claims a capability that is not built and proven, or states a plan without indicating where it is tracked.",
        true:
          "Every capability stated exists and is proven by a test, ledger row, or screenshot; every plan is stated as a plan with a tracking location."
      })

      version(1)
      family(:agent_reply_style)
      profile(:winnow_gpu)
      state_projection(AshEnterprise.Quality.Projections.ReplyText)
      state_shape(AshEnterprise.Quality.Projections.ReplyText.shape())
    end

    question :hs5_promise_only_agreed_to do
      # judgment:v0:AshEnterprise.Quality.AgentReply#judgments/hs5_promise_only_agreed_to
      type AshAi.Evaluate.Noul

      instructions(
        "Check if the reply adheres to the 'Promise only what someone has agreed to' standard."
      )

      criteria(%{
        false:
          "The reply includes dates, scope, or commitments that the person with the authority has not made, or fails to state when something cannot be committed.",
        true:
          "The reply contains no dates, scope, or commitments that the person with the authority has not made, and explicitly states when something cannot be committed."
      })

      version(1)
      family(:agent_reply_style)
      profile(:winnow_gpu)
      state_projection(AshEnterprise.Quality.Projections.ReplyText)
      state_shape(AshEnterprise.Quality.Projections.ReplyText.shape())
    end

    question :hs6_no_novelty_claims do
      # judgment:v0:AshEnterprise.Quality.AgentReply#judgments/hs6_no_novelty_claims
      type AshAi.Evaluate.Noul
      instructions("Check if the reply adheres to the 'No novelty claims' standard.")

      criteria(%{
        false:
          "The reply describes an idea as novel, new, first, unprecedented, or something nobody has done.",
        true:
          "The reply does not describe any idea as novel, new, first, unprecedented, or something nobody has done, instead stating what the design does and why it was chosen."
      })

      version(1)
      family(:agent_reply_style)
      profile(:winnow_gpu)
      state_projection(AshEnterprise.Quality.Projections.ReplyText)
      state_shape(AshEnterprise.Quality.Projections.ReplyText.shape())
    end

    question :hs7_never_invent_name_feature_or_date do
      # judgment:v0:AshEnterprise.Quality.AgentReply#judgments/hs7_never_invent_name_feature_or_date
      type AshAi.Evaluate.Noul

      instructions(
        "Check if the reply adheres to the 'Never invent a name, a feature or a date' standard."
      )

      criteria(%{
        false:
          "The reply invents names, features, or dates, or uses relative time expressions like 'last week' or 'recently' instead of specific dates.",
        true:
          "The reply uses only names already used by the code and product, and gives dates as specific dates (e.g., 2026-10-17) rather than relative time expressions."
      })

      version(1)
      family(:agent_reply_style)
      profile(:winnow_gpu)
      state_projection(AshEnterprise.Quality.Projections.ReplyText)
      state_shape(AshEnterprise.Quality.Projections.ReplyText.shape())
    end

    question :hs8_no_internal_shorthand_for_outside do
      # judgment:v0:AshEnterprise.Quality.AgentReply#judgments/hs8_no_internal_shorthand_for_outside
      type AshAi.Evaluate.Noul

      instructions(
        "Check if the reply adheres to the 'No internal shorthand where a customer or outside contributor reads' standard."
      )

      criteria(%{
        false:
          "The reply contains ticket keys, internal codenames, or team jargon in product copy, public docs, or anything sent outside.",
        true:
          "The reply contains no ticket keys, internal codenames, or team jargon in product copy, public docs, or anything sent outside, spelling out the meaning instead."
      })

      version(1)
      family(:agent_reply_style)
      profile(:winnow_gpu)
      state_projection(AshEnterprise.Quality.Projections.ReplyText)
      state_shape(AshEnterprise.Quality.Projections.ReplyText.shape())
    end
  end
end
