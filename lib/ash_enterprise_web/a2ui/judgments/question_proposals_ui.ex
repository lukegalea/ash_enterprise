defmodule AshEnterpriseWeb.A2ui.Judgments.QuestionProposalsUI do
  @moduledoc """
  Questions an in-zone instrument drafted from policy text, awaiting a
  person's confirmation (S1-61, ADR 0061). The surface is this
  application's own, because `AshEnterprise.SystemOne.QuestionProposal` is
  a host record, not a package fragment.

  Each row is one proposal: where its policy text came from, the
  questions it proposes, the instrument that drafted it and when.
  **Details** shows every question in full: its wording, the answers it
  may give, the criteria for each and the state shape it reads.

  **Confirm questions** runs the proposal's `:confirm` as the person
  clicking, with the entries as proposed: the action re-validates and
  re-hashes every one, so the confirmed declaration is the one the person
  read. Its policies require a person who holds a role granting write on
  proposals; an agent or a system actor is refused. The button shows
  only on a proposal still `:proposed`, and the list holds only those, so
  a confirmed proposal leaves it. Confirming registers nothing: the
  declaration lands when a person commits it (`QuestionProposal.to_dsl/2`).

  It replaces the handoff script (`confirm-v2-as-luke.exs`) that ran
  `QuestionProposal.confirm/3` over `:erpc` as the confirming person.
  Served at `/app/judgments/question-proposals`.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.SystemOne.QuestionProposal
    surface_id "judgment_question_proposals"
    title "Question proposals"
    record_label "question proposal"

    context :proposal do
      resource AshEnterprise.SystemOne.QuestionProposal
      picker false
    end

    query :awaiting do
      sortable [:created_on]
      default_sort created_on: :asc
      page_size 25

      empty_state title: "No questions await confirmation",
                  message:
                    "Questions an instrument drafts from policy text appear here " <>
                      "until a person confirms them."
    end

    component :table do
      fields [:source, :question_names, :profile, :created_on]
      read_action :awaiting_confirmation
      query :awaiting
      row_actions [:confirm]
      select_context :proposal

      row_layout do
        title :source
        meta [:question_names, :profile, :created_on]
        columns 1
      end
    end

    component :detail, :proposal_detail do
      context :proposal
      fields [:source, :policy_digest, :questions]
    end

    action :confirm do
      label "Confirm questions"
      visible_when status: :proposed
    end

    field :source do
      label "Drafted from"
    end

    field :question_names do
      label "Questions"
    end

    field :questions do
      label "The questions in full"
    end

    field :profile do
      label "Instrument"
    end

    field :policy_digest do
      label "Policy digest"
    end

    field :created_on do
      label "Proposed"
    end
  end
end
