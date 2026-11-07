defmodule AshEnterpriseWeb.ArtifactLiveTest do
  @moduledoc """
  The artifact pages (`/app/artifacts`): discovery, one version's header, validation and
  semantic diff, and the run it was opened from. A draft reads as a draft and never as the
  version a run used; nothing that could not be compared, read or checked reads as "No
  changes" or as valid.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import AshEnterpriseWeb.RunCueAssertions

  alias AshEnterprise.Execution.{AgentVersion, Run}
  alias AshEnterprise.Quality
  alias AshEnterprise.Test.AssistantFixtures
  alias AshEnterpriseWeb.ArtifactComponents

  setup do
    admin = AssistantFixtures.tenant!()
    opts = [actor: admin.actor, tenant: admin.tenant]
    one = %{id: "one", input: "SYNTHETIC: the referral names no clinician"}
    two = %{id: "two", input: "SYNTHETIC: the referral is urgent"}

    v1 =
      "clinic.triage"
      |> Quality.create_suite_draft!(%{cases: [one]}, opts)
      |> Quality.publish_suite!(opts)

    v2 = Quality.create_suite_draft!("clinic.triage", %{cases: [one, two]}, opts)

    %{admin: admin, v1: v1, v2: v2}
  end

  defp sign_in(user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp agent!(admin, version, status) do
    Ash.Seed.seed!(AgentVersion, %{
      organization_id: admin.tenant,
      key: "clinic.triager",
      version: version,
      source: :code,
      instructions: "SYNTHETIC: read the referral, v#{version}.",
      model_profile: "in_zone",
      toolset: [],
      limits: %{max_steps: 4},
      output_type: "string",
      content_hash: "h#{version}",
      status: status
    })
  end

  defp run!(admin, version, mode) do
    Ash.Seed.seed!(Run, %{
      organization_id: admin.tenant,
      owner_type: :user,
      owner_id: admin.user.id,
      agent_key: version.key,
      agent_version_id: version.id,
      run_key: "artifact-#{System.unique_integer([:positive])}",
      mode: mode,
      status: :completed
    })
  end

  describe "discovery" do
    test "lists the versions the viewer may read, by type", %{admin: admin, v1: v1, v2: v2} do
      {:ok, view, _html} = live(sign_in(admin.user), "/app/artifacts")

      assert has_element?(view, "#artifacts-suite")
      assert has_element?(view, "#artifact-suite-#{v1.id}[data-lifecycle=current]")
      assert has_element?(view, "#artifact-suite-#{v2.id}[data-lifecycle=draft]")
      assert has_element?(view, "#context-band")
    end
  end

  describe "one version" do
    test "a suite draft: its header, its validation and what it adds to the version before",
         %{admin: admin, v1: v1, v2: v2} do
      {:ok, view, _html} = live(sign_in(admin.user), "/app/artifacts/suite/#{v2.id}")

      assert has_element?(view, "#artifact-header[data-lifecycle=draft]")
      assert has_element?(view, "#artifact-header-draft-note")
      assert has_element?(view, "#artifact-header-version", "version 2")
      assert has_element?(view, "#artifact-validation[data-validation=valid]")
      assert has_element?(view, "#artifact-diff[data-diff-state=changes]")
      assert has_element?(view, "#artifact-diff-cases [data-change-kind=added]", "two")
      assert has_element?(view, "#artifact-diff-compares", "Cases")
      assert has_element?(view, "#compare-#{v1.id}")
    end

    test "the published suite is in use, first, and says who published it",
         %{admin: admin, v1: v1} do
      {:ok, view, _html} = live(sign_in(admin.user), "/app/artifacts/suite/#{v1.id}")

      assert has_element?(view, "#artifact-header[data-lifecycle=current]")
      refute has_element?(view, "#artifact-header-draft-note")
      assert has_element?(view, "#artifact-diff[data-diff-state=first]")
      refute render(view) =~ "No changes"

      assert has_element?(
               view,
               "#artifact-header-published-by[data-published-by=recorded]",
               to_string(admin.user.email)
             )
    end

    test "compared with a version that cannot be read, no changes are shown, and not as none",
         %{admin: admin, v2: v2} do
      {:ok, view, _html} =
        live(sign_in(admin.user), "/app/artifacts/suite/#{v2.id}?from=#{Ecto.UUID.generate()}")

      assert has_element?(view, "#artifact-diff[data-diff-state=unreadable]")
      refute render(view) =~ "No changes"
    end

    test "a version the viewer cannot read shows nothing of it", %{v2: v2} do
      stranger = AssistantFixtures.tenant!()
      {:ok, view, _html} = live(sign_in(stranger.user), "/app/artifacts/suite/#{v2.id}")

      refute has_element?(view, "#artifact-header")
      assert render(view) =~ "No version you can read has this address."

      {:ok, view, _html} = live(sign_in(stranger.user), "/app/artifacts/nonsense/#{v2.id}")
      refute has_element?(view, "#artifact-header")
    end
  end

  describe "opened from a run (UX-04)" do
    setup %{admin: admin} do
      published = agent!(admin, 1, :published)
      draft = agent!(admin, 2, :draft)
      %{published: published, draft: draft, run: run!(admin, published, :live)}
    end

    test "the version the run used says so, with the run's cue", ctx do
      {:ok, view, _html} =
        live(
          sign_in(ctx.admin.user),
          "/app/artifacts/agent/#{ctx.published.id}?run=#{ctx.run.id}"
        )

      assert has_element?(view, "#artifact-header[data-lifecycle=current]")
      assert has_element?(view, "#artifact-header-run[data-used-by=this]")
      assert has_element?(view, "#artifact-header-run-mode[data-run-environment=live]")
    end

    test "a draft is visibly a draft and never the version the run used", ctx do
      {:ok, view, _html} =
        live(sign_in(ctx.admin.user), "/app/artifacts/agent/#{ctx.draft.id}?run=#{ctx.run.id}")

      assert has_element?(view, "#artifact-header[data-lifecycle=draft]")
      assert has_element?(view, "#artifact-header-lifecycle[data-lifecycle=draft]", "Draft")
      assert has_element?(view, "#artifact-header-draft-note")
      assert has_element?(view, "#artifact-header-run[data-used-by=other]")
      refute has_element?(view, "#artifact-header-run[data-used-by=this]")

      assert has_element?(
               view,
               ~s(#artifact-header-run-used[href="/app/artifacts/agent/#{ctx.published.id}"])
             )
    end

    test "a test run's version carries the test cue, never a live claim", ctx do
      eval = run!(ctx.admin, ctx.published, :eval)

      {:ok, view, _html} =
        live(sign_in(ctx.admin.user), "/app/artifacts/agent/#{ctx.published.id}?run=#{eval.id}")

      assert assert_test_cue(view, "#artifact-header-run") == ["eval"]
      refute_live_claim(view, "#artifact-header")
    end

    test "a run that cannot be read does not say which version it used", ctx do
      {:ok, view, _html} =
        live(
          sign_in(ctx.admin.user),
          "/app/artifacts/agent/#{ctx.published.id}?run=#{Ecto.UUID.generate()}"
        )

      assert has_element?(view, "#artifact-header-run[data-used-by=unreadable]")
      refute has_element?(view, "#artifact-header-run[data-used-by=this]")
      refute_live_claim(view, "#artifact-header")
    end
  end

  describe "the diff component" do
    defp diff(state, aspects \\ [cases: "Cases"]),
      do: render_component(&ArtifactComponents.artifact_diff/1, state: state, aspects: aspects)

    test "only a comparison that ran and found nothing says No changes" do
      assert diff({:unchanged, :same_content}) =~ "No changes"
      assert diff({:unchanged, :compared}) =~ "No changes"

      for state <- [
            :no_differ,
            :first,
            :unchained,
            :uncovered,
            {:unreadable, :from},
            {:failed, "the differ broke"},
            {:failed, :unreadable},
            {:changes, []}
          ] do
        refute diff(state) =~ "No changes", inspect(state)
      end
    end

    test "a type with no differ says so, and is not an empty diff" do
      html = diff(:no_differ, [])
      assert html =~ "No semantic diff for this type"
      assert html =~ ~s(data-diff-state="no-differ")
    end

    test "a failed or unreadable comparison is an alert" do
      for state <- [{:failed, :boom}, {:unreadable, :from}] do
        assert diff(state) =~ ~s(role="alert")
      end
    end
  end

  describe "the validation component" do
    defp validation(state),
      do: render_component(&ArtifactComponents.artifact_validation/1, validation: state)

    test "only a check that ran and found nothing is valid" do
      assert validation({:ok, []}) =~ ~s(data-validation="valid")

      for state <- [{:ok, ["a problem"]}, :undeclared, {:failed, :not_compiled}, {:failed, :x}] do
        html = validation(state)
        refute html =~ ~s(data-validation="valid"), inspect(state)
        refute html =~ "no problems found", inspect(state)
      end
    end
  end
end
