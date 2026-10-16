defmodule AshEnterpriseWeb.A2ui.MdmStewardUI do
  @moduledoc """
  The steward's queue (ADR 0054, MDM-4): review-banded match candidates
  awaiting a person's decision, oldest first, each with the staged-vs-golden
  side-by-side and the matcher's per-rule explanation.

  * **Confirm match** merges the staged record into the golden record.
  * **Reject match** leaves the staged record a record of its own (the only
    act offered in bulk — a merge is decided one pair at a time).
  * **Mark unsure** records the verdict and keeps the candidate open for a
    senior steward.

  Each button is shown only while the candidate is pending, and runs the
  candidate's person-gated update as the clicking person
  (`AshEnterprise.Mdm.MatchCandidate`). The diff is calculations on the
  candidate read under the reader's policies: a steward who may not read a
  staged row sees that side empty. The queue lists no candidate whose golden
  the reader may not read (Person is owner-only), so it never discloses that
  such a golden exists, and Confirm match refuses one opened by id. There
  is no second security model and no unauthorized read.

  Served at `/app/mdm`.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Mdm.MatchCandidate
    surface_id "mdm_steward"
    title "Steward queue"
    record_label "match candidate"

    context :candidate do
      resource AshEnterprise.Mdm.MatchCandidate
      picker false
    end

    query :queue do
      sortable [:created_on, :score]
      default_sort created_on: :asc
      page_size 25
      max_page_size 50
    end

    component :table do
      fields [:staged_label, :golden_label, :score, :waiting_since]
      read_action :review_queue
      query :queue
      row_actions [:confirm_match, :reject_match, :mark_unsure]
      bulk_actions [:reject_match]
      select_context :candidate

      row_layout do
        title :staged_label
        meta [:golden_label, :score, :waiting_since]
        columns 2
      end
    end

    component :detail, :candidate_detail do
      context :candidate

      fields [
        :staged_name,
        :golden_name,
        :name_survivor,
        :staged_email,
        :golden_email,
        :email_survivor,
        :score,
        :explanation_text,
        :golden_label,
        :staged_batch_label
      ]
    end

    action :confirm_match do
      visible_when status: :pending
    end

    action :reject_match do
      visible_when status: :pending
    end

    action :mark_unsure do
      visible_when status: :pending
    end

    field :staged_label do
      label "Staged record"
    end

    # Through the `golden` relationship, loaded under the reader's policies:
    # a golden they may not read yields no id, so no link.
    field :golden_label do
      label "Possible duplicate of"
      link {:mdm_golden, [:golden, :id]}
    end

    # A staged row has no surface of its own; its home is its import batch,
    # whose detail lists the batch's staged rows.
    field :staged_batch_label do
      label "Staged in"
      link {:mdm_batches, [:staged_record, :batch_id]}
    end

    field :score do
      label "Score"
    end

    field :waiting_since do
      label "Waiting since"
    end

    field :staged_name do
      label "Name (staged)"
    end

    field :golden_name do
      label "Name (golden)"
    end

    field :name_survivor do
      label "Name kept on confirm"
    end

    field :staged_email do
      label "Email (staged)"
    end

    field :golden_email do
      label "Email (golden)"
    end

    field :email_survivor do
      label "Email kept on confirm"
    end

    field :explanation_text do
      label "Why it matched"
    end
  end
end
