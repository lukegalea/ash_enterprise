# Compiled only when ash_agent_tools is loaded (dev and test). The fragment
# this resource is built on ships in that dependency, which production does
# not carry; see AshEnterprise.Standards.
if Code.ensure_loaded?(AshAgentTools.CodeSubjects.Fragment) do
  defmodule AshEnterprise.Standards.CodeUnit do
    @moduledoc """
    A unit of our own source (a module, a function, a DSL entity or a doc
    paragraph), as the subject the engineering standards are judged over
    (AST-138).

    The shape is `AshAgentTools.CodeSubjects.Fragment`'s: an address
    (`"<repository>:<path>#<name_path>"`) that survives unrelated edits, a
    clickable `path:line` and the unit's text. Units are read from a
    checkout by the `:scan` action and never stored: the facts about them
    live in `AshEnterprise.SystemOne.Fact`, keyed by
    `AshEnterprise.Standards.subject_term/1`.

    ## The questions

    The seventeen questions below are Luke Galea's confirmation of
    2026-10-21 (dogfood records `61a388e9-1f61-4bdd-913b-ab45f61590a6`, the
    CLAUDE.md non-negotiables; `04d37ab9-e18b-401e-8b89-02473d5619ae`, the
    iron laws; `dee2d586-d943-4c2f-8e01-bbb06866efe3`, the house style),
    rendered by `AshEnterprise.SystemOne.QuestionProposal.to_dsl/2` and
    landed verbatim at version 1 with the `:winnow_gpu` decision instrument.
    Their hashes are locked in `priv/judgments/lock.json`, so a wording
    change is a compile error until it arrives with a version bump.

    Each question names the projection it sees
    (`AshEnterprise.Standards.Projections`). None declares a `state_shape`:
    the shape is part of a question's hash, and the confirmed hashes were
    taken without one. Declaring it is a new question identity, for a
    version bump and a fresh confirmation.

    Which units each question is asked about is
    `AshEnterprise.Standards.Candidates`' decision, never a model's.

    Not persisted (`Ash.DataLayer.Simple`), so there is nothing to audit,
    archive, emit lineage for or hold per tenant: `audit?: false`,
    `archival?: false`, `lineage?: false`, `tenant?: false` and
    `ownership: :none`. Authorization is the platform's standard set, so
    the standing job runs as a system actor and a person needs a grant.
    """

    use AshEnterprise.Platform.Resource,
      domain: AshEnterprise.Standards,
      data_layer: Ash.DataLayer.Simple,
      ownership: :none,
      tenant?: false,
      lifecycle?: false,
      audit?: false,
      archival?: false,
      lineage?: false,
      fragments: [AshAgentTools.CodeSubjects.Fragment],
      extra_extensions: [AshAi, AshJudgments.Registry]

    judgments do
      question :no_forbid_if_for_row_access do
        # judgment:v0:AshEnterprise.Standards.CodeUnit#judgments/no_forbid_if_for_row_access
        type AshAi.Evaluate.Noul

        instructions(
          "Inspect any `forbid_if` clauses in the resource's authorization logic. If any `forbid_if` condition restricts row visibility or editability based on data attributes (row access), the answer is false. If `forbid_if` is absent or used only for system-level states (not row data), the answer is true."
        )

        criteria(%{
          false:
            "The code uses `forbid_if` to control row-level access (filtering or restricting which records a user can see/edit).",
          true:
            "The code does not use `forbid_if` for row-level access. `forbid_if` may only be present for non-row concerns like disabled accounts or dead tenants."
        })

        version(1)
        family(:security)
        profile(:winnow_gpu)
        state_projection(AshEnterprise.Standards.Projections.PolicyView)
      end

      question :policy_check_never_queries do
        # judgment:v0:AshEnterprise.Standards.CodeUnit#judgments/policy_check_never_queries
        type AshAi.Evaluate.Noul

        instructions(
          "Analyze the code path for the policy check. Does it execute any database queries or network calls to fetch data? If yes, the answer is false. If it only reads from the provided `AshEnterprise.Security.ActorContext` or other precomputed in-memory structures, the answer is true."
        )

        criteria(%{
          false:
            "The policy check or its dependencies issue database queries (e.g., `Ash.Query`, `Ecto` calls, or any I/O that retrieves data from the database) during execution.",
          true:
            "The policy check performs no queries. All required data (team ids, business-unit subtree, privilege map, reporting chain) is read from the precomputed `AshEnterprise.Security.ActorContext` or in-memory state."
        })

        version(1)
        family(:performance)
        profile(:winnow_gpu)
        state_projection(AshEnterprise.Standards.Projections.PolicyView)
      end

      question :handle_event_authorizes do
        # judgment:v0:AshEnterprise.Standards.CodeUnit#judgments/handle_event_authorizes
        type AshAi.Evaluate.Noul
        instructions("Does the event handler perform authorization via Ash actions or Ash.can?")

        criteria(%{
          false:
            "The event handler does not route through Ash actions with policies or check Ash.can?",
          true: "The event handler routes through Ash actions with policies or checks Ash.can?"
        })

        version(1)
        family(:authorization)
        profile(:winnow_gpu)
        state_projection(AshEnterprise.Standards.Projections.ModuleHeader)
      end

      question :comments_are_durable_facts_only do
        # judgment:v0:AshEnterprise.Standards.CodeUnit#judgments/comments_are_durable_facts_only
        type AshAi.Evaluate.Noul

        instructions(
          "Do the code comments contain only durable facts, reserving narrative for commit messages?"
        )

        criteria(%{
          false: "The comments contain narrative that belongs in a commit message",
          true: "The comments contain only durable facts, with narrative excluded"
        })

        version(1)
        family(:commenting)
        profile(:winnow_gpu)
        state_projection(AshEnterprise.Standards.Projections.Text)
      end

      question :association_query_strategy do
        # judgment:v0:AshEnterprise.Standards.CodeUnit#judgments/association_query_strategy
        type AshAi.Evaluate.Choice
        constraints(of: [:has_many_separate_queries, :belongs_to_join, :joins_has_many])
        instructions("Which query strategy is used for the association?")

        criteria(%{
          belongs_to_join: "Uses JOIN for belongs_to associations",
          has_many_separate_queries:
            "Uses separate queries for has_many associations to avoid N+1 and row multiplication",
          joins_has_many:
            "Joins a has_many association in one query, multiplying rows (what the law forbids)"
        })

        version(1)
        family(:query_strategy)
        profile(:winnow_gpu)
        state_projection(AshEnterprise.Standards.Projections.ModuleHeader)
      end

      question :oban_args_string_keyed do
        # judgment:v0:AshEnterprise.Standards.CodeUnit#judgments/oban_args_string_keyed
        type AshAi.Evaluate.Noul
        instructions("Are Oban job arguments string-keyed rather than atom-keyed?")

        criteria(%{
          false: "Args use atom keys",
          true: "Args are string-keyed to survive JSON serialization"
        })

        version(1)
        family(:oban_serialization)
        profile(:winnow_gpu)
        state_projection(AshEnterprise.Standards.Projections.ModuleHeader)
      end

      question :stores_ids_not_structs do
        # judgment:v0:AshEnterprise.Standards.CodeUnit#judgments/stores_ids_not_structs
        type AshAi.Evaluate.Noul
        instructions("Are IDs stored and passed instead of entire structs?")

        criteria(%{
          false: "Structs are stored and passed directly, freezing state",
          true: "IDs are stored and passed to allow fresh re-reading"
        })

        version(1)
        family(:state_persistence)
        profile(:winnow_gpu)
        state_projection(AshEnterprise.Standards.Projections.ModuleHeader)
      end

      question :third_party_api_wrapped do
        # judgment:v0:AshEnterprise.Standards.CodeUnit#judgments/third_party_api_wrapped
        type AshAi.Evaluate.Noul
        instructions("Is the third-party API wrapped in a dedicated façade module?")

        criteria(%{
          false: "Third-party API calls are made directly without a façade",
          true: "Third-party APIs are wrapped in a single façade module per external service"
        })

        version(1)
        family(:external_services)
        profile(:winnow_gpu)
        state_projection(AshEnterprise.Standards.Projections.FacadeView)
      end

      question :hs1_lead_with_outcome_or_ask do
        # judgment:v0:AshEnterprise.Standards.CodeUnit#judgments/hs1_lead_with_outcome_or_ask
        type AshAi.Evaluate.Noul

        instructions(
          "Check if the document's first sentence follows the 'Lead with the outcome or the ask' standard."
        )

        criteria(%{
          false:
            "The first sentence of the document does not state what happened, what the reader must decide, or what the thing does.",
          true:
            "The first sentence of the document states what happened, what the reader must decide, or what the thing does."
        })

        version(1)
        family(:house_style)
        profile(:winnow_gpu)
        state_projection(AshEnterprise.Standards.Projections.Text)
      end

      question :hs2_keep_it_short do
        # judgment:v0:AshEnterprise.Standards.CodeUnit#judgments/hs2_keep_it_short
        type AshAi.Evaluate.Noul

        instructions(
          "Check if the document adheres to the 'Keep it short' standard regarding paragraph length and list formatting."
        )

        criteria(%{
          false:
            "The document contains paragraphs that are not short or lists of more than three items that are not presented as a table or a list.",
          true:
            "The document uses short paragraphs and presents items as a table or a list when there are more than three of anything."
        })

        version(1)
        family(:house_style)
        profile(:winnow_gpu)
        state_projection(AshEnterprise.Standards.Projections.Text)
      end

      question :hs3_use_plain_words do
        # judgment:v0:AshEnterprise.Standards.CodeUnit#judgments/hs3_use_plain_words
        type AshAi.Evaluate.Noul
        instructions("Check if the document adheres to the 'Use plain words' standard.")

        criteria(%{
          false:
            "The document uses complex phrasing, filler openers, repeated apologies, or exclamation marks.",
          true:
            "The document uses plain words, avoids filler openers, apologises at most once, and contains no exclamation marks."
        })

        version(1)
        family(:house_style)
        profile(:winnow_gpu)
        state_projection(AshEnterprise.Standards.Projections.Text)
      end

      question :hs4_claim_only_built_and_proven do
        # judgment:v0:AshEnterprise.Standards.CodeUnit#judgments/hs4_claim_only_built_and_proven
        type AshAi.Evaluate.Noul

        instructions(
          "Check if the document adheres to the 'Claim only what is built and proven' standard."
        )

        criteria(%{
          false:
            "The document claims a capability that is not built and proven, or states a plan without indicating where it is tracked.",
          true:
            "Every capability stated exists and is proven by a test, ledger row, or screenshot; every plan is stated as a plan with a tracking location."
        })

        version(1)
        family(:house_style)
        profile(:winnow_gpu)
        state_projection(AshEnterprise.Standards.Projections.Text)
      end

      question :hs5_promise_only_agreed_to do
        # judgment:v0:AshEnterprise.Standards.CodeUnit#judgments/hs5_promise_only_agreed_to
        type AshAi.Evaluate.Noul

        instructions(
          "Check if the document adheres to the 'Promise only what someone has agreed to' standard."
        )

        criteria(%{
          false:
            "The document includes dates, scope, or commitments that the person with the authority has not made, or fails to state when something cannot be committed.",
          true:
            "The document contains no dates, scope, or commitments that the person with the authority has not made, and explicitly states when something cannot be committed."
        })

        version(1)
        family(:house_style)
        profile(:winnow_gpu)
        state_projection(AshEnterprise.Standards.Projections.Text)
      end

      question :hs6_no_novelty_claims do
        # judgment:v0:AshEnterprise.Standards.CodeUnit#judgments/hs6_no_novelty_claims
        type AshAi.Evaluate.Noul
        instructions("Check if the document adheres to the 'No novelty claims' standard.")

        criteria(%{
          false:
            "The document describes an idea as novel, new, first, unprecedented, or something nobody has done.",
          true:
            "The document does not describe any idea as novel, new, first, unprecedented, or something nobody has done, instead stating what the design does and why it was chosen."
        })

        version(1)
        family(:house_style)
        profile(:winnow_gpu)
        state_projection(AshEnterprise.Standards.Projections.Text)
      end

      question :hs7_never_invent_name_feature_or_date do
        # judgment:v0:AshEnterprise.Standards.CodeUnit#judgments/hs7_never_invent_name_feature_or_date
        type AshAi.Evaluate.Noul

        instructions(
          "Check if the document adheres to the 'Never invent a name, a feature or a date' standard."
        )

        criteria(%{
          false:
            "The document invents names, features, or dates, or uses relative time expressions like 'last week' or 'recently' instead of specific dates.",
          true:
            "The document uses only names already used by the code and product, and gives dates as specific dates (e.g., 2026-10-17) rather than relative time expressions."
        })

        version(1)
        family(:house_style)
        profile(:winnow_gpu)
        state_projection(AshEnterprise.Standards.Projections.Text)
      end

      question :hs8_no_internal_shorthand_for_outside do
        # judgment:v0:AshEnterprise.Standards.CodeUnit#judgments/hs8_no_internal_shorthand_for_outside
        type AshAi.Evaluate.Noul

        instructions(
          "Check if the document adheres to the 'No internal shorthand where a customer or outside contributor reads' standard."
        )

        criteria(%{
          false:
            "The document contains ticket keys, internal codenames, or team jargon in product copy, public docs, or anything sent outside.",
          true:
            "The document contains no ticket keys, internal codenames, or team jargon in product copy, public docs, or anything sent outside, spelling out the meaning instead."
        })

        version(1)
        family(:house_style)
        profile(:winnow_gpu)
        state_projection(AshEnterprise.Standards.Projections.Text)
      end

      question :hs9_interface_copy_languages do
        # judgment:v0:AshEnterprise.Standards.CodeUnit#judgments/hs9_interface_copy_languages
        type AshAi.Evaluate.Choice
        constraints(of: [:done, :not_done, :customer_facing_other])

        instructions(
          "Assess the status of product interface copy and other customer-facing writing regarding English and French availability."
        )

        criteria(%{
          customer_facing_other:
            "For other customer-facing writing, the document has checked whether a French version is needed rather than assuming English is enough.",
          done: "Every user-facing string has both an English and a French version.",
          not_done: "At least one user-facing string lacks either an English or a French version."
        })

        version(1)
        family(:house_style)
        profile(:winnow_gpu)
        state_projection(AshEnterprise.Standards.Projections.ModuleHeader)
      end
    end
  end
end
