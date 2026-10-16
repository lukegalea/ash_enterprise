defmodule AshEnterpriseWeb.A2ui.MdmGoldenUI do
  @moduledoc """
  A2UI surface over the canonical Person goldens — the merged view of the
  customer. A row opens its detail with what the pipeline knows about it:
  the source identities folded into it (the XREF) and the match candidates
  that paired staged rows with it (its merge history). A merged record's
  detail links the golden that absorbed it (`master`).

  Person is owner-only (ADR 0042): no grant reaches beyond `:basic`, so the
  table, the detail and the `master` link show the people the reader owns
  and nothing more. The related tables read `SourceIdentity` and
  `MatchCandidate` under their own policies. Read-only; goldens change
  through imports and the steward's verdicts.

  Served at `/app/mdm/golden`; `/app/r/mdm_golden/:id` deep-links one record.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource(AshEnterprise.Canonical.Person)
    surface_id("mdm_golden")
    title("Golden records")
    record_label("golden record")

    context :person do
      resource(AshEnterprise.Canonical.Person)
      picker(false)
    end

    query :default do
      search_fields([:name, :email])
      sortable([:name, :email, :created_on])
      default_sort(name: :asc)
      page_size(25)
    end

    query :history do
      sortable([:created_on])
      default_sort(created_on: :desc)
      page_size(10)
      max_page_size(50)
    end

    component :table do
      fields([:name, :email])
      read_action(:goldens)
      query(:default)
      select_context(:person)

      row_layout do
        title(:name)
        meta([:email])
        columns(2)
      end
    end

    component :detail, :person_detail do
      context(:person)
      fields([:name, :email, :absorbed_by])
    end

    component :table, :identities do
      resource(AshEnterprise.Mdm.SourceIdentity)
      fields([:source, :stream, :external_id, :asserted_by, :confidence])
      context_filter(golden_id: :person)
      require_context([:person])
    end

    component :table, :merge_history do
      resource(AshEnterprise.Mdm.MatchCandidate)
      fields([:staged_label, :status, :band, :score, :waiting_since])
      query(:history)
      context_filter(golden_id: :person)
      require_context([:person])
    end

    field :absorbed_by do
      label("Merged into")
      link({:mdm_golden, [:master, :id]})
    end

    field :source do
      label("Source")
    end

    field :stream do
      label("Stream")
    end

    field :external_id do
      label("Source id")
    end

    field :asserted_by do
      label("Asserted by")
    end

    field :staged_label do
      label("Staged record")
    end

    field :waiting_since do
      label("Proposed")
    end
  end
end
