defmodule AshEnterprise.Provenance do
  @moduledoc """
  Where a value came from (ADR 0078): one question — `explain/2` — asked of any
  value a person can read, answered as that person, through one dispatch.

  An answer is `AshProvenance.Explanation`: PROV-DM steps and typed gaps over the
  subject address (`<base>/<type>/<id>#<attribute>`), bounded by depth and step
  count, with nothing in it the reader could not have read one record at a time.
  The dispatch order is the explainer registry's (`AshEnterprise.Provenance.Registry`);
  every read an explainer makes is the reader's own, through the record's own
  read action, so the explain action grants nothing and is declared self-service
  (ADR 0052).

  A value the reader may not see is masked, never empty; an unreadable subject is
  not found; where the answer stops it says why with a typed gap. See ADR 0078
  for the decision and `deps/ash_provenance` for the contract the answer speaks.
  """

  use Ash.Domain

  @doc """
  The base IRI of every value address: the endpoint's URL plus `/id`
  (ADR 0078, section 1).
  """
  @spec base() :: String.t()
  def base, do: AshEnterpriseWeb.Endpoint.url() <> "/id"

  resources do
    resource AshEnterprise.Provenance.Explanation do
      define :explain, action: :explain, args: [:address]
    end
  end
end
