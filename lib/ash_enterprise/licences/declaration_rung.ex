defmodule AshEnterprise.Licences.DeclarationRung do
  @moduledoc """
  The declaration-first rung of the licence policy (S1-63/AC-2): a release
  that declares exactly one SPDX id the policy classifies is answered from
  that id. Deterministic, no model, and no I/O at call time.

  The classification table is policy data, `priv/licences/spdx_classes.csv`:
  per SPDX id, its category (permissive, weak, strong or network copyleft,
  public-domain equivalent), whether the licence requires its notice to
  travel with copies, and whether it restricts use. The table is read at
  compile time; editing it recompiles this module, and changes the gold
  labels the model rung is calibrated against.

  What a declaration settles, per confirmed question:

    * the four category questions, attribution, public-domain dedication and
      use restriction: from the table row;
    * `package_licence_declaration_invalid`: `false` (the declaration is a
      classified SPDX id);
    * `package_requires_notice_file`: `false` for every id but Apache-2.0.
      For Apache-2.0 the declaration says nothing about a NOTICE file, so
      the answer is `:needs_package_contents` (see
      `AshEnterprise.Licences.Rungs`).
  """

  alias NimbleCSV.RFC4180, as: CSV

  @table_path Path.join([__DIR__, "..", "..", "..", "priv", "licences", "spdx_classes.csv"])
  @external_resource @table_path

  @categories %{
    "permissive" => :permissive,
    "weak_copyleft" => :weak_copyleft,
    "strong_copyleft" => :strong_copyleft,
    "network_copyleft" => :network_copyleft,
    "public_domain_equivalent" => :public_domain_equivalent
  }

  @classes @table_path
           |> File.read!()
           |> CSV.parse_string(skip_headers: false)
           |> then(fn [header | rows] ->
             Enum.map(rows, fn row -> header |> Enum.zip(row) |> Map.new() end)
           end)
           |> Map.new(fn row ->
             {row["spdx_id"],
              %{
                category: Map.fetch!(@categories, row["category"]),
                attribution_required?: row["attribution_required"] == "true",
                use_restricted?: row["use_restricted"] == "true"
              }}
           end)

  @type answer :: boolean() | :needs_package_contents

  @doc "The SPDX ids the policy classifies."
  @spec classified_ids() :: [String.t()]
  def classified_ids, do: Map.keys(@classes)

  @doc "The classification row for an SPDX id, or nil."
  @spec classification(String.t()) :: map() | nil
  def classification(spdx_id), do: Map.get(@classes, spdx_id)

  @doc """
  The declared SPDX id this rung can answer from: the release's only
  declared licence, when the policy classifies it. Otherwise `:none`.
  """
  @spec declared_id(map()) :: {:ok, String.t()} | :none
  def declared_id(%{declared_licences: [id]}) when is_map_key(@classes, id), do: {:ok, id}
  def declared_id(_subject), do: :none

  @doc """
  The nine answers for a classified SPDX id, keyed by question name.
  """
  @spec answers(String.t()) :: %{atom() => answer()}
  def answers(spdx_id) do
    %{category: category, attribution_required?: attribution, use_restricted?: restricted} =
      Map.fetch!(@classes, spdx_id)

    %{
      package_licence_is_permissive: category in [:permissive, :public_domain_equivalent],
      package_licence_is_strong_copyleft: category == :strong_copyleft,
      package_licence_is_weak_copyleft: category == :weak_copyleft,
      package_licence_is_network_copyleft: category == :network_copyleft,
      package_licence_requires_attribution: attribution,
      package_requires_notice_file:
        if(spdx_id == "Apache-2.0", do: :needs_package_contents, else: false),
      package_licence_declaration_invalid: false,
      package_is_public_domain_dedication: category == :public_domain_equivalent,
      package_licence_has_use_restrictions: restricted
    }
  end
end
