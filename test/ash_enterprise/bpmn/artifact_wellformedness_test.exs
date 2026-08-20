defmodule AshEnterprise.Bpmn.ArtifactWellformednessTest do
  @moduledoc """
  Every BPMN and DMN artifact this application ships parses as namespaced XML.

  This exists because one of them did not, and nothing noticed.
  `priv/bpmn/access_request_grant.bpmn` used `xsi:type` on four
  `conditionExpression` elements and never declared `xmlns:xsi`, which makes it
  well-formed XML but *not* namespace-well-formed. It survived because the
  compiler reads BPMN with `:xmerl` in a non-namespace-aware mode, where an
  undeclared prefix is just part of the attribute name.

  The consequence is not cosmetic. bpmn-js parses through moddle, which *is*
  namespace-aware, so the document that compiled and executed perfectly on the
  server was a document the designer would refuse to open — a discrepancy that
  surfaces as an editor that will not load a process the engine is happily
  running, which is close to the worst place to discover it.

  Asserting on the strict parser rather than on the one the compiler uses is the
  whole point: a test that used `:xmerl` the way the compiler does would have
  passed on the broken file.
  """

  use ExUnit.Case, async: true

  @artifacts Path.wildcard("priv/bpmn/*.bpmn") ++ Path.wildcard("priv/dmn/*.dmn")

  test "there are artifacts to check" do
    # Without this, the suite below passes vacuously if the directories are ever
    # renamed or the wildcard stops matching.
    assert length(@artifacts) >= 2, "expected priv/bpmn and priv/dmn to hold documents"
  end

  for artifact <- @artifacts do
    test "#{artifact} is namespace-well-formed" do
      xml = File.read!(unquote(artifact))

      # `:xmerl_scan` with namespace_conformant declines an undeclared prefix,
      # which is exactly the check the compiler's own parse does not make.
      result =
        try do
          {:ok, :xmerl_scan.string(String.to_charlist(xml), namespace_conformant: true)}
        catch
          :exit, reason -> {:error, reason}
          kind, reason -> {:error, {kind, reason}}
        end

      assert match?({:ok, _}, result),
             """
             #{unquote(artifact)} is not namespace-well-formed: #{inspect(result)}

             Most likely an XML prefix is used without a matching xmlns: declaration on
             the root element. The compiler will not care; bpmn-js and dmn-js will.
             """
    end
  end
end
