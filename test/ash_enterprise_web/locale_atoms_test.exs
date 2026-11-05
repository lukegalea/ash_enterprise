defmodule AshEnterpriseWeb.LocaleAtomsTest do
  @moduledoc """
  Locale codes arrive from request headers. Parsing them must never create an
  atom, or a stream of crafted `Accept-Language` headers grows the atom table
  until the node dies.
  """

  # async: false -- it reads the VM-wide atom count, which any test running
  # beside it could move.
  use ExUnit.Case, async: false

  alias AshEnterpriseWeb.Locale

  test "parsing unknown and invalid codes creates no atoms" do
    inputs =
      for n <- 1..2_000 do
        suffix = Integer.to_string(n, 36)
        "zz-#{suffix}, q#{suffix}-QQ;q=0.#{rem(n, 9) + 1}, x#{suffix}y;q=bad, fr-#{suffix}"
      end

    # Warm up: load every module and code path once before counting.
    _ = Enum.map(Enum.take(inputs, 5), &Locale.resolve(accept_language: &1, organization: &1))

    before = :erlang.system_info(:atom_count)

    for header <- inputs do
      Locale.resolve(accept_language: header, organization: header, user: header)
      Locale.parse_tag(header)
      Locale.known(header)
    end

    assert :erlang.system_info(:atom_count) == before
  end
end
