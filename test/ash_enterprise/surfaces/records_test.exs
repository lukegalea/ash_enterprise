defmodule AshEnterprise.Surfaces.RecordsTest do
  @moduledoc """
  Opening one record on its registry surface (`AshEnterprise.Surfaces.Records`)
  and which surface a link opens (`AshEnterprise.Surfaces.LinkResolver`): both
  re-decided per actor — doors, authorized reads, the surface's own context
  selection. SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures

  alias AshEnterprise.Canonical.{Conversation, Person}
  alias AshEnterprise.Erasure.Scope
  alias AshEnterprise.Surfaces.{LinkResolver, Records}

  test "a readable record opens selected; anything else is one answer" do
    ctx = tenant!()
    other = tenant!()
    ada = person!(ctx, "ada@example.test", "Ada Park")
    theirs = person!(other, "theirs@example.test", "Not Yours")

    assert {:ok, %{surface: %{key: :people}, context_state: state, path: path}} =
             Records.open("people", ada.id, ctx.actor)

    assert state["person"]["value"] == ada.id
    assert state["person"]["label"] == "Ada Park"
    assert path =~ "/app/people?ctx"

    assert {:error, :not_found} = Records.open(:people, theirs.id, ctx.actor)
    assert {:error, :not_found} = Records.open(:people, "nope", ctx.actor)
    assert {:error, {:no_surface, "nowhere"}} = Records.open("nowhere", ada.id, ctx.actor)
    assert Records.message(:not_found) =~ "not found, or it is not yours"
  end

  test "doors hold: erasure is the platform operator's" do
    ctx = tenant!()
    operator = tenant!(operator?: true)
    scope = scope!()

    assert {:error, {:door_closed, text}} = Records.open(:erasure, scope.id, ctx.actor)
    assert text =~ "platform operator"

    assert {:ok, %{surface: %{key: :erasure}}} = Records.open(:erasure, scope.id, operator.actor)
  end

  test "the link resolver maps records to surfaces and vetoes closed doors" do
    ctx = tenant!()
    operator = tenant!(operator?: true)

    assert LinkResolver.surface_for({:resource, Person}, %{actor: ctx.actor}) == "people"
    assert LinkResolver.surface_for({:resource, Conversation}, %{actor: ctx.actor}) == "inbox"
    assert LinkResolver.surface_for({:resource, Scope}, %{actor: ctx.actor}) == nil
    assert LinkResolver.surface_for({:resource, Scope}, %{actor: operator.actor}) == "erasure"
    assert LinkResolver.surface_for({:surface, "users"}, %{actor: ctx.actor}) == "users"
    # A surface with no detail is no link target.
    assert LinkResolver.surface_for({:surface, "roles"}, %{actor: ctx.actor}) == nil
    assert LinkResolver.surface_for({:surface, "record"}, %{actor: ctx.actor}) == "record"
    assert LinkResolver.surface_for({:resource, Person}, %{actor: nil}) == nil
  end
end
