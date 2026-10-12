defmodule AshEnterprise.Canonical.Projections.ZoneGate.DenyAll do
  @moduledoc """
  The default zone gate: admits nothing (ADR 0042). See
  `AshEnterprise.Canonical.Projections.ZoneGate`.
  """

  @behaviour AshEnterprise.Canonical.Projections.ZoneGate

  @impl true
  def admit(_source, _context), do: {:deny, :zone_admission_not_wired}
end
