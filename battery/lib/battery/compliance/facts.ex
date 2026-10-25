defmodule Battery.Compliance.Facts do
  @moduledoc """
  The compliance projector's fact extraction: facts about a vendor are read
  off the BIZEV projection (`Battery.BusinessEvents.VendorState`), NOT off
  the event payload — the projected state is the substrate's answer to
  "what is true about this subject now".

  Triples are in the POST-COMPILE spelling (the bundle crossed
  encode/decode on its way through the compliance plane): the subject is
  the string `"vendor"`, the predicates are the schema's declared atoms.
  """

  require Ash.Query

  @doc "The `:facts` MFA: `{Battery.Compliance.Facts, :from_event, []}`."
  def from_event(event) do
    metadata = event.metadata || %{}
    subject_id = metadata["subject_id"]
    region = metadata["region"]

    with {:ok, state} <- projected_vendor(subject_id, region) do
      {:ok,
       [
         {"vendor", :vendor_reviewed, true},
         {"vendor", :vendor_approved, state.review_status == "approved"}
       ]}
    end
  end

  defp projected_vendor(subject_id, region) do
    Battery.BusinessEvents.VendorState
    |> Ash.Query.filter(subject == ^subject_id and region == ^region)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, "no projected vendor state for #{inspect(subject_id)}"}
      {:ok, state} -> {:ok, state}
      {:error, error} -> {:error, error}
    end
  end
end
