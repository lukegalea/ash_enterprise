defmodule AshEnterprise.Execution.Release.Attestation do
  @moduledoc """
  A release manifest as an in-toto Statement v1
  (https://github.com/in-toto/attestation/blob/main/spec/v1/statement.md): what was
  released, and the gate result that let it through.

    * `subject`: the manifest itself, named `<key>@<seq>` with its digest, then every entry
      as the `ResourceDescriptor` it was resolved to;
    * `predicateType`: `#{"https://github.com/lukegalea/ash_enterprise/release-gate/v1"}`;
    * `predicate`: the manifest's key, version, status and promotion time, and the gate's
      result with the suite runs it rests on.

  A statement is an export, built from the row as it stands: it carries no signature, and
  nothing here claims it is signed.
  """

  @statement_type "https://in-toto.io/Statement/v1"
  @predicate_type "https://github.com/lukegalea/ash_enterprise/release-gate/v1"

  @doc "The in-toto Statement for `manifest` (a resolved or later one)."
  @spec statement(map()) :: map()
  def statement(manifest) do
    %{
      "_type" => @statement_type,
      "subject" => [manifest_descriptor(manifest) | Enum.map(manifest.entries, &descriptor/1)],
      "predicateType" => @predicate_type,
      "predicate" => %{
        "key" => manifest.key,
        "version" => manifest.version,
        "status" => to_string(manifest.status),
        "promotedAt" => manifest.promoted_at && DateTime.to_iso8601(manifest.promoted_at),
        "gate" => manifest.gate_result,
        "suiteRunIds" => manifest.suite_run_ids
      }
    }
  end

  defp manifest_descriptor(manifest) do
    %{
      "name" => "#{manifest.key}@#{manifest.version}",
      "digest" => %{"sha256" => manifest.manifest_digest}
    }
  end

  defp descriptor(entry), do: Map.take(entry, ["name", "uri", "digest"])
end
