defmodule AshEnterprise.Legacy.StranglerCodegenTest do
  @moduledoc """
  The legacy domain attaches `AshStrangler.Codegen`, so `mix ash.codegen
  --check` covers the strangler compatibility layer. These are the fast,
  database-free form of that gate: the committed snapshot matches what the
  library renders today.
  """
  use ExUnit.Case, async: true

  test "the legacy domain attaches the strangler codegen extension" do
    assert AshEnterprise.Legacy in AshStrangler.Codegen.attached_domains([AshEnterprise.Legacy])
    assert AshEnterprise.Legacy.User in AshStrangler.Codegen.covered_resources()
  end

  test "the committed strangler snapshot matches the rendered statements" do
    assert AshStrangler.Codegen.pending() == []
  end
end
