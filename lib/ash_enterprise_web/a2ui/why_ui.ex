defmodule AshEnterpriseWeb.A2ui.WhyUI do
  @moduledoc """
  Where a value came from (ADR 0078): the address of one readable value in, and
  the steps and gaps of its answer out, as the signed-in person may read them.

  A report over `AshEnterprise.Provenance.Explanation.why`, which answers through
  the same `explain` the assistant's tool does and projects it into the same rows
  (`AshEnterprise.Provenance.Why`). A value the reader may not see reads as the
  masked text, never as an empty cell, and an answer that stops says where and why in
  a row of its own.

  Served at `/app/why` behind the `ont_why` flag (`AshEnterprise.Surfaces.Doors`).
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource(AshEnterprise.Provenance.Explanation)
    surface_id("why")
    title("Where a value came from")
    record_label("step")

    component :report, :why do
      action(:why)
      params([:address])
      fields([:what, :value, :by, :at, :summary, :granularity, :context, :integrity, :plan])
    end

    field :address do
      label("Address of the value")
    end

    field :what do
      label("What")
    end

    field :value do
      label("Value")
    end

    field :by do
      label("By")
    end

    field :at do
      label("When")
    end

    field :summary do
      label("Summary")
    end

    field :granularity do
      label("About")
    end

    field :context do
      label("Context")
    end

    field :integrity do
      label("Chain")
    end

    field :plan do
      label("Plan")
    end
  end
end
