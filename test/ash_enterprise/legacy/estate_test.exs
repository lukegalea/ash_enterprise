defmodule AshEnterprise.Legacy.EstateTest do
  @moduledoc """
  The legacy estate's two fixed ids: that they are read off the mapping rather
  than restated, and what advisory lock key they derive.

  The second half exists to keep a note honest. `AshEnterprise.Legacy.Estate`
  documents that both ids derive `[0, 0]` and explains why that is accepted; that
  explanation depends on how `AshEvents.AdvisoryLockKeyGenerator.Default` samples
  a uuid, which is a dependency's implementation detail and not a schema
  guarantee. If the sampling changes, the prose becomes wrong silently. This makes
  it fail instead.
  """

  use AshEnterprise.DataCase, async: true

  alias AshEnterprise.Legacy.Estate

  # The generator's derivation, restated here on purpose rather than called.
  #
  # `uuid_to_int/1` is a private function of the dependency, so there is nothing
  # to call. Restating it is the point: this test compares OUR expectation of the
  # sampling against the key an audited write actually takes, and a divergence is
  # exactly the signal wanted.
  defp derive_key(uuid) do
    <<hi::binary-size(8), lo::binary-size(8)>> =
      uuid |> String.replace("-", "") |> Base.decode16!(case: :mixed)

    <<hi_int::signed-32, _rest::binary>> = hi
    <<lo_int::signed-32, _rest::binary>> = lo

    [hi_int, lo_int]
  end

  describe "the fixed ids" do
    test "are read off the mapping, not restated beside it" do
      # The literals live in `AshEnterprise.Legacy.User`'s `strangler` block
      # because the view's SELECT list needs them checked in. Reading them back
      # is what stops the seed and the DDL drifting apart.
      constants = AshStrangler.Info.constants(AshEnterprise.Legacy.User)

      for {attribute, expected} <- [
            {:organization_id, Estate.organization_id()},
            {:owning_business_unit_id, Estate.business_unit_id()}
          ] do
        entity = Enum.find(constants, &(&1.attribute == attribute))

        assert %{expression: %Ash.Query.Call{name: :type, args: [^expected, :uuid]}} = entity
      end
    end

    test "are distinct, so the two rows they name are distinct" do
      refute Estate.organization_id() == Estate.business_unit_id()
    end
  end

  describe "the advisory lock key they derive" do
    test "is [0, 0] for both, which is what the note in Estate explains" do
      # Not an aspiration. Measured from a real audited write: the trace was
      # `begin / INSERT roles / SELECT pg_advisory_xact_lock(0, 0) /
      # INSERT audit_events / commit`.
      assert derive_key(Estate.organization_id()) == [0, 0]
      assert derive_key(Estate.business_unit_id()) == [0, 0]
    end

    test "cannot distinguish the two ids, because they differ in a discarded byte" do
      # The `fe`/`fd` suffix is byte 15. The generator reads bytes 0-3 and 8-11.
      # This is the whole reason a vanity id was the wrong instinct: the part
      # chosen to be meaningful is the part thrown away.
      assert derive_key(Estate.organization_id()) == derive_key(Estate.business_unit_id())
    end

    test "an ordinary random tenant id does not derive [0, 0]" do
      # Without this the test above would still pass if the sampling changed to
      # something that returns [0, 0] for everything -- which would mean every
      # tenant serialized against every other, a real performance cliff, and the
      # note in Estate would be describing the wrong world.
      for _ <- 1..50 do
        refute derive_key(Ash.UUID.generate()) == [0, 0]
      end
    end

    test "a further hand-picked id in the same shape would collide" do
      # The consequence the note warns about, asserted so it is not just prose.
      # Varying only the discarded bytes is not enough.
      assert derive_key("00000000-0000-0000-0000-0000000000aa") ==
               derive_key(Estate.organization_id())

      # Varying a sampled byte range is.
      refute derive_key("00000001-0000-0000-0000-0000000000fe") ==
               derive_key(Estate.organization_id())

      refute derive_key("00000000-0000-0000-0001-0000000000fe") ==
               derive_key(Estate.organization_id())
    end
  end
end
