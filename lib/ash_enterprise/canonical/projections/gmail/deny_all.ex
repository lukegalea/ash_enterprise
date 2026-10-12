defmodule AshEnterprise.Canonical.Projections.Gmail.DenyAll do
  @moduledoc """
  The default Gmail zone gate: admits nothing (ADR 0042). See
  `AshEnterprise.Canonical.Projections.Gmail.ZoneGate`.
  """

  @behaviour AshEnterprise.Canonical.Projections.Gmail.ZoneGate

  @impl true
  def admit(_source, _context), do: {:deny, :zone_admission_not_wired}
end
