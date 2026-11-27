if Code.ensure_loaded?(AshJourneys.Info) do
  defmodule AshBrowserTests.Journeys do
    @moduledoc """
    Runs the journeys a host declares with `ash_journeys` in a real browser: one
    test per journey per locale, which walks the journey's steps as its personas,
    proves each step's expectations, captures its figures and writes the run
    manifest `mix ash_journeys.approve` reads.

        defmodule MyAppWeb.E2E.JourneysTest do
          use AshBrowserTests.Journeys,
            host: MyAppWeb.E2E.JourneyHost,
            journeys: [MyApp.Journeys.Offboarding],
            async: true
        end

    `host` implements `AshBrowserTests.Journeys.Host`. Other options are
    `AshBrowserTests.Case`'s; `:timeout` defaults to three minutes. It needs
    `ash_journeys` (an optional dependency of this package), and `ash_a2ui` for a
    journey that acts on A2UI rows.

    ## A run

    Before the first step the test checks the journey against its surfaces as
    they render in the locale (`AshJourneys.Preflight.check/3`), seeds its world
    and pins its timestamps (`AshJourneys.World`), resolves the journey's texts in
    the locale (`AshJourneys.L10n.texts/3`), and signs every persona in, each in a
    browser context of its own (`AshJourneys.Persona`, then
    `c:AshBrowserTests.Journeys.Host.sign_in/3`). The contexts share the test's
    sandbox and test key, and each has its own `AshBrowserTests.FailureCapture`.

    Then each step, as its persona, in order:

      * a span cursor is taken before the step acts
        (`AshBrowserTests.Trace.cursor/2`), and every trace expectation of the
        step is asserted against it: a span lost in one step fails that step,
        never the next;
      * `open` visits the surface's path; `row_action` performs the manifest's row
        action on the bound record's row (`AshBrowserTests.RowActions`), leaving
        a declared confirmation open until the step's next entry that is not a
        `:dialog` figure;
      * every `figure` and every `expect` first waits for the page to settle
        (`AshBrowserTests.Settle`); a page that does not settle fails the step
        with the state it saw, and is never shot anyway;
      * `figure` captures the page, the confirmation dialog, a table or a bound
        record's row under `framing/1`, with its masks, and records the file and
        raster hashes and the highlighted row's box;
      * `expect` asserts the trace chain (and one correlation id), the audit row
        each of the step's row actions wrote
        (`c:AshBrowserTests.Journeys.Host.assert_audit/3`), a bound record's
        attributes, or the surface the persona landed on;
      * when the step is done, a console error, page error or 5xx that any
        persona's browser context reported during it fails the step, unless the
        test is tagged `allow_browser_failures: true`. So a run whose browser
        reported a failure is never recorded as passed.

    A step that fails stops the journey: the steps after it are recorded as
    skipped and never run. Every error is prefixed with the journey, the locale,
    the step and its persona: `journey revoke_a_leavers_access (en), step
    03-deactivate (as admin): …`.

    ## What it writes

    The manifest (`AshJourneys.Manifest`) and the figures, named
    `<step>.<figure>.png`, go to the run's candidate directory
    (`AshBrowserTests.Journeys.Candidates`), whether the journey passed or not.
    The step's cursor window, its correlation id and span ids, each figure's
    settled state and hashes, and the journey's texts are recorded as measured,
    and nothing unmeasured is filled in. The run's retries count the earlier
    attempts of the same run (`AshBrowserTests.Journeys.Candidates`). The
    driver's own end-of-test screenshot is off for these tests.

    A browser failure reported after the last step, before the test ends, still
    fails the test at exit (`AshBrowserTests.Case`); the runner then rewrites the
    manifest as failed, so it never says passed.
    """

    alias AshBrowserTests.Browser
    alias AshBrowserTests.FailureCapture
    alias AshBrowserTests.Figure
    alias AshBrowserTests.Journeys.Candidates
    alias AshBrowserTests.Ledger
    alias AshBrowserTests.RowActions
    alias AshBrowserTests.Trace
    alias AshBrowserTests.Trace.Cursor
    alias AshJourneys.Dsl
    alias AshJourneys.Info
    alias AshJourneys.Ir
    alias AshJourneys.L10n
    alias AshJourneys.Lock
    alias AshJourneys.Manifest
    alias AshJourneys.Preflight
    alias AshJourneys.Raster

    @compile {:no_warn_undefined, [Ash, AshA2ui.Manifest, PhoenixTest.Playwright]}

    @correlation_id "ash.correlation_id"
    @dialog ~s|:is([role="dialog"], [role="alertdialog"], dialog[open]) >> visible=true|

    defmacro __using__(opts) do
      {host, opts} = Keyword.pop!(opts, :host)
      {journeys, opts} = Keyword.pop!(opts, :journeys)
      opts = Keyword.put_new(opts, :timeout, 180_000)

      quote do
        use AshBrowserTests.Case, unquote(opts)

        # A journey's figures are its own, under the runner's names; the driver's
        # end-of-test screenshot would add one more file per browser context.
        @moduletag screenshot: false

        @journeys_host unquote(host)

        for {module, name, locale} <- AshBrowserTests.Journeys.planned(unquote(journeys)) do
          @tag journey: {module, name, locale}
          @tag browser_context_opts: AshBrowserTests.Journeys.framing(locale)
          test "journey #{name} (#{locale})", context do
            AshBrowserTests.Journeys.run!(@journeys_host, context.journey, context)
          end
        end
      end
    end

    @doc "Every journey and locale `modules` declare, as `{module, name, locale}`."
    @spec planned([module()]) :: [{module(), atom(), String.t()}]
    def planned(modules) do
      for module <- modules,
          journey <- Info.journeys(module),
          locale <- journey.locales,
          do: {module, journey.name, Atom.to_string(locale)}
    end

    @typedoc "A journey and locale whose approved run does not prove it, and why."
    @type unproven :: {String.t(), String.t(), Lock.refusal(), [String.t()]}

    @doc """
    What the journeys `modules` declare walk, for the documentation ledger
    (`AshBrowserTests.Ledger.documentation_problems/3`), counting only the
    journeys the lock under the project root `root` holds current in every
    locale they declare (`AshJourneys.Lock.check/4`: approved, and not stale,
    altered or drifted). A counted journey walks each surface a step is on, as
    `{:journey, id, {:surface, surface_id}}`, and each row action a step
    performs, as `{:journey, id, {:action, surface_id, "row:" <> row_action_id}}`.
    The others are `unproven`, one entry per locale that is not current, with
    the lock's reasons. `opts` are `AshJourneys.Lock.verify/6`'s.
    """
    @spec proven([module()], Path.t(), keyword()) ::
            {:ok, %{documented: [AshBrowserTests.Ledger.documented()], unproven: [unproven()]}}
            | {:error, [String.t()]}
    def proven(modules, root, opts \\ []) do
      with {:ok, declared} <- Lock.declared(modules),
           {:ok, lock} <- Lock.read(root) do
        status = Lock.check(root, lock, declared, opts)
        current = MapSet.new(status.current)

        unproven =
          Enum.sort(
            for({id, locale} <- status.unapproved, do: {id, locale, :unapproved, []}) ++
              for(
                refusal <- [:stale, :altered, :drifted],
                {id, locale, reasons} <- Map.fetch!(status, refusal),
                do: {id, locale, refusal, reasons}
              )
          )

        documented =
          for module <- modules,
              journey <- Info.journeys(module),
              id = Atom.to_string(journey.name),
              Enum.all?(declared[id].ir["locales"], &MapSet.member?(current, {id, &1})),
              entry <- walks(journey),
              uniq: true,
              do: entry

        {:ok, %{documented: documented, unproven: unproven}}
      end
    end

    @doc """
    The documentation ledger of a host's declared surfaces
    (`AshBrowserTests.Surfaces.declared/1` of `surfaces_host`, and its waivers),
    walked by the journeys `modules` declare that the lock proves (`proven/3`).
    Raises `ExUnit.AssertionError` on any problem of
    `AshBrowserTests.Ledger.documentation_problems/3`. The message names every
    journey that was not counted, and why.

    `opts`: `:root`, the project root the lock is read under (the current
    directory by default); the rest are `AshJourneys.Lock.verify/6`'s.
    """
    @spec assert_documented!(module(), [module()], keyword()) :: :ok
    def assert_documented!(surfaces_host, modules, opts \\ []) do
      {root, opts} = Keyword.pop_lazy(opts, :root, &File.cwd!/0)

      %{documented: documented, unproven: unproven} =
        case proven(modules, root, opts) do
          {:ok, proven} ->
            proven

          {:error, problems} ->
            raise ExUnit.AssertionError,
              message:
                "the journeys or their lock do not read:\n  " <> Enum.join(problems, "\n  ")
        end

      problems =
        Ledger.documentation_problems(
          AshBrowserTests.Surfaces.declared(surfaces_host),
          surfaces_host.waivers(),
          documented
        )

      if problems != [] do
        raise ExUnit.AssertionError,
          message:
            "the documentation ledger is not complete:\n" <>
              Enum.map_join(problems, "\n", &Ledger.format_problem/1) <>
              Enum.map_join(unproven, "", &uncounted/1)
      end

      :ok
    end

    defp uncounted({id, locale, refusal, reasons}) do
      "\n  journey #{id} walks nothing yet: #{locale} is #{refusal}" <>
        Enum.map_join(reasons, "", &"\n    #{&1}")
    end

    defp walks(journey) do
      for {step, surface} <- Ir.step_surfaces(journey),
          surface != nil,
          key <- [{:surface, Atom.to_string(surface)} | row_actions(step, surface)],
          uniq: true,
          do: {:journey, Atom.to_string(journey.name), key}
    end

    defp row_actions(step, surface) do
      for %Dsl.RowAction{id: id} <- step.body,
          do: {:action, Atom.to_string(surface), "row:" <> id}
    end

    @doc """
    The browser-context options every persona context of a journey in `locale`
    is created with: `AshBrowserTests.Figure.framing/1` in that locale.
    """
    @spec framing(String.t()) :: keyword()
    def framing(locale), do: Figure.framing(locale: locale)

    @doc """
    Runs journey `name` of `module` in `locale` against `host`, in the test whose
    ExUnit context is `context` (it needs the `AshBrowserTests.Case` context:
    `:conn`, `:test_key`, `:browser_id`). Writes the run manifest and returns it;
    raises, after writing it, when the journey did not pass.
    """
    @spec run!(module(), {module(), atom(), String.t()}, map()) :: Manifest.t()
    def run!(host, {module, name, locale}, context) do
      journey = Info.journey!(module, name)
      ir = Ir.build(journey)
      claim = Candidates.claim!(File.cwd!(), Candidates.run_id(), ir["id"], locale)

      run = %{
        host: host,
        module: module,
        journey: journey,
        ir: ir,
        locale: locale,
        context: context,
        key: context.test_key,
        dir: claim.dir,
        bindings: %{},
        conns: %{},
        captures: %{},
        texts: nil
      }

      {run, results, failure} =
        case prepare(run) do
          {:ok, run} ->
            {results, failure} = run_steps(run)
            {run, results, failure}

          {:error, error, stacktrace} ->
            {run, skipped(journey), {nil, error, stacktrace}}
        end

      manifest = manifest(run, claim, results)
      Manifest.write!(manifest, claim.dir)
      seal_on_exit(run, manifest, claim.dir)
      warn_if_flaky(manifest, claim.dir)

      case failure do
        nil -> manifest
        {label, error, stacktrace} -> reraise prefixed(run, label, error, claim.dir), stacktrace
      end
    end

    # --- Before the first step -------------------------------------------------------

    defp prepare(run) do
      :ok = preflight!(run)
      run = %{run | texts: texts!(run)}
      bindings = seed!(run)
      run = %{run | bindings: bindings}
      {conns, captures} = sign_in_personas(run)
      {:ok, %{run | conns: conns, captures: captures}}
    rescue
      error -> {:error, error, __STACKTRACE__}
    end

    defp preflight!(%{module: module, journey: journey, host: host, locale: locale}) do
      case Preflight.check(module, journey.name, host.manifest_opts(locale)) do
        :ok ->
          :ok

        {:error, errors} ->
          raise ExUnit.AssertionError,
            message: "the start-of-run check failed:\n" <> Enum.map_join(errors, "\n", &"  #{&1}")
      end
    end

    # What the run's pages will say, resolved as the surfaces render in this
    # locale: the manifest records it, and a projection shows it only while it
    # still resolves the same.
    defp texts!(%{module: module, ir: ir, host: host, locale: locale}) do
      case L10n.texts(%{module: module, ir: ir}, locale, host.manifest_opts(locale)) do
        {:ok, texts} ->
          texts

        {:error, errors} ->
          raise ExUnit.AssertionError,
            message:
              "the journey's text does not resolve:\n" <> Enum.map_join(errors, "\n", &"  #{&1}")
      end
    end

    defp seed!(%{journey: %{world: nil}}), do: %{}

    defp seed!(%{journey: %{world: world} = journey, module: module, locale: locale}) do
      world_module = Info.world_module(module)

      bindings =
        case world_module.seed(world, journey: journey.name, locale: locale) do
          {:ok, bindings} -> bindings
          {:error, reason} -> raise "the world did not seed: #{inspect(reason)}"
        end

      if world.clock do
        pins =
          Map.new(world.timestamps, fn {binding, attributes} ->
            {binding,
             Map.new(attributes, fn {attr, offset} -> {attr, Ir.offset_seconds(offset)} end)}
          end)

        case world_module.pin_timestamps(bindings, world.clock, pins) do
          :ok -> :ok
          {:error, reason} -> raise "the world's timestamps were not pinned: #{inspect(reason)}"
        end
      end

      bindings
    end

    # The first persona signs in on the test's own browser context; every other
    # persona gets a new context in the same browser, through the setup the case
    # template ran for the first. Its user agent carries the same sandbox
    # metadata, so its requests share the test's sandbox and its spans the test's
    # key.
    defp sign_in_personas(%{journey: journey, module: module, host: host} = run) do
      personas = Info.persona_module(module)

      signed_in =
        journey.personas
        |> Enum.with_index()
        |> Enum.map(fn {persona, index} ->
          {conn, capture} =
            if index == 0,
              do: {run.context.conn, run.context[:browser_failures]},
              else: new_context(run.context, persona.name)

          actor =
            case personas.actor(persona.role, persona.name, run.bindings) do
              {:ok, actor} -> actor
              {:error, reason} -> raise "persona #{persona.name} has no actor: #{inspect(reason)}"
            end

          {persona.name, host.sign_in(conn, actor, host_context(run, persona.name)), capture}
        end)

      {Map.new(signed_in, fn {name, conn, _capture} -> {name, conn} end),
       for({name, _conn, capture} <- signed_in, capture != nil, into: %{}, do: {name, capture})}
    end

    defp new_context(context, persona) do
      [conn: conn] = PhoenixTest.Playwright.Case.do_setup(context)
      capture = FailureCapture.start!(conn)
      strict? = not Map.get(context, :allow_browser_failures, false)

      ExUnit.Callbacks.on_exit(fn ->
        failures = FailureCapture.stop(capture)

        if strict? and failures != [] do
          raise ExUnit.AssertionError,
            message: "persona #{persona}: " <> FailureCapture.format(failures)
        end
      end)

      {conn, capture}
    end

    defp host_context(run, persona) do
      Map.merge(run.context, %{locale: run.locale, persona: persona, bindings: run.bindings})
    end

    # --- The steps ---------------------------------------------------------------------

    defp run_steps(run) do
      steps = Ir.step_surfaces(run.journey)

      {results, {_run, failure}} =
        steps
        |> Enum.with_index(1)
        |> Enum.map_reduce({run, nil}, fn
          {{step, _surface}, _n}, {run, failure} when failure != nil ->
            {skipped_step(step), {run, failure}}

          {{step, surface}, n}, {run, nil} ->
            {result, run, failure} = run_step(run, step, surface, n)
            {result, {run, failure}}
        end)

      {close_windows(results, run.key), failure}
    end

    defp run_step(run, %Dsl.Step{} = step, surface, n) do
      label = "#{String.pad_leading(Integer.to_string(n), 2, "0")}-#{step.name}"

      acc = %{
        run: run,
        step: step,
        surface: surface,
        cursor: Trace.cursor(run.key, label),
        figures: [],
        correlation_id: nil,
        span_ids: [],
        unconfirmed: nil,
        acted: [],
        started_at: DateTime.utc_now()
      }

      {acc, error} =
        Enum.reduce_while(step.body ++ [:end_of_step], {acc, nil}, fn entity, {acc, nil} ->
          case attempt(acc, entity) do
            {:ok, acc} -> {:cont, {acc, nil}}
            {:error, error, stacktrace} -> {:halt, {acc, {error, stacktrace}}}
          end
        end)

      error = error || browser_failures(acc.run)

      cursor = Cursor.close(acc.cursor)

      result = %{
        name: Atom.to_string(step.name),
        actor: Atom.to_string(step.as),
        label: label,
        status: status(error),
        cursor: cursor,
        correlation_id: acc.correlation_id,
        span_ids: acc.span_ids,
        figures: Enum.reverse(acc.figures),
        error: error && Exception.message(elem(error, 0))
      }

      failure = error && {label <> " (as #{step.as})", elem(error, 0), elem(error, 1)}
      {result, acc.run, failure}
    end

    # What any persona's browser reported going wrong since the last step, taken
    # from its capture so the step, not the test's exit, reports it. A round trip
    # to each page first delivers the events it has already sent.
    defp browser_failures(%{context: context} = run) do
      if Map.get(context, :allow_browser_failures, false) do
        nil
      else
        failures =
          for {persona, capture} <- Enum.sort(run.captures),
              failure <- take_failures(run.conns[persona], capture),
              do: {persona, failure}

        case failures do
          [] ->
            nil

          failures ->
            message =
              failures
              |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
              |> Enum.map_join("\n", fn {persona, failures} ->
                "persona #{persona}: " <> FailureCapture.format(failures)
              end)

            {%ExUnit.AssertionError{message: message}, []}
        end
      end
    end

    defp take_failures(conn, capture) do
      _ = conn && PhoenixTest.Playwright.evaluate(conn, "1")
      FailureCapture.take(capture, ~r//)
    catch
      :exit, _closed -> FailureCapture.take(capture, ~r//)
    end

    # A failure reported after the last step's check fails the test at exit, in
    # the capture's own callback, registered before this one and so run after it.
    # Before that, the manifest of a passed run is rewritten as failed.
    defp seal_on_exit(%{context: context} = run, %Manifest{status: :passed} = manifest, dir) do
      unless Map.get(context, :allow_browser_failures, false) do
        captures = Map.values(run.captures)

        ExUnit.Callbacks.on_exit(fn ->
          late = Enum.flat_map(captures, &FailureCapture.failures/1)

          if late != [] do
            message = "after the last step: " <> FailureCapture.format(late)

            steps =
              List.update_at(manifest.steps, -1, fn step ->
                %{step | status: :failed, error: message}
              end)

            Manifest.write!(%{manifest | status: :failed, steps: steps}, dir)
          end
        end)
      end

      :ok
    end

    defp seal_on_exit(_run, _manifest, _dir), do: :ok

    defp status(nil), do: :passed
    defp status({%ExUnit.AssertionError{}, _stacktrace}), do: :failed
    defp status({_error, _stacktrace}), do: :errored

    defp attempt(acc, entity) do
      {:ok, act(acc, entity)}
    rescue
      error -> {:error, error, __STACKTRACE__}
    catch
      :exit, reason ->
        {:error, %RuntimeError{message: "exited: #{inspect(reason, limit: 5)}"}, __STACKTRACE__}
    end

    defp act(acc, :end_of_step), do: confirm_pending(acc)

    defp act(acc, %Dsl.Figure{frame: :dialog} = figure), do: capture(acc, figure)
    defp act(acc, %Dsl.Figure{} = figure), do: acc |> confirm_pending() |> capture(figure)

    defp act(acc, %Dsl.Open{surface: surface}) do
      acc = confirm_pending(acc)
      put_conn(acc, PhoenixTest.visit(conn(acc), acc.run.host.path(surface, acc.run.bindings)))
    end

    defp act(acc, %Dsl.RowAction{} = row_action) do
      acc = confirm_pending(acc)
      action = row_action!(acc, row_action.id)
      record = binding!(acc.run, row_action.on)
      row = %{id: to_string(record.id), text: "#{row_action.on} (#{record.id})", inputs: %{}}

      conn = RowActions.perform(conn(acc), row, action, confirm: not row_action.confirm)
      acted = %{resource: action.resource, action: action.ash_action, record: record}
      acc = %{put_conn(acc, conn) | acted: acc.acted ++ [acted]}
      if row_action.confirm, do: %{acc | unconfirmed: action}, else: acc
    end

    defp act(acc, %Dsl.Expect{} = expect) do
      acc = confirm_pending(acc)

      acc =
        if expect.lands_on do
          path = acc.run.host.path(expect.lands_on, acc.run.bindings)
          put_conn(acc, PhoenixTest.assert_path(conn(acc), path, timeout: 15_000))
        else
          acc
        end

      acc
      |> settle()
      |> expect_trace(expect)
      |> expect_audit(expect)
      |> expect_record(expect)
    end

    defp confirm_pending(%{unconfirmed: nil} = acc), do: acc

    defp confirm_pending(%{unconfirmed: action} = acc) do
      %{put_conn(acc, RowActions.confirm(conn(acc), action)) | unconfirmed: nil}
    end

    defp settle(acc) do
      {conn, _state} = AshBrowserTests.Settle.wait!(conn(acc))
      put_conn(acc, conn)
    end

    # --- Expectations ------------------------------------------------------------------

    defp expect_trace(acc, %Dsl.Expect{trace: []}), do: acc

    defp expect_trace(acc, %Dsl.Expect{trace: kinds} = expect) do
      acc = put_conn(acc, Browser.flush_browser_spans(conn(acc)))

      chain =
        case Enum.map(kinds, &matcher/1) do
          [one] -> [Trace.assert_span(acc.cursor, one)]
          matchers -> Trace.assert_chain(acc.cursor, matchers)
        end

      root = hd(chain)

      correlation_id =
        if expect.one_correlation do
          Trace.assert_one_correlation(
            acc.cursor,
            &(&1.trace_id == root.trace_id and &1.span_id == root.span_id)
          )
        else
          Enum.find_value(chain, & &1.attributes[@correlation_id])
        end

      span_ids =
        if correlation_id do
          for span <- Trace.spans(acc.cursor),
              span.attributes[@correlation_id] == correlation_id,
              do: span.span_id
        else
          Enum.map(chain, & &1.span_id)
        end

      %{
        acc
        | correlation_id: correlation_id,
          span_ids: Enum.uniq(acc.span_ids ++ Enum.map(chain, & &1.span_id) ++ span_ids)
      }
    end

    defp matcher({:ash_action, action}), do: Trace.ash_action(action: action)
    defp matcher(kind), do: apply(Trace, kind, [])

    defp expect_audit(acc, %Dsl.Expect{audit: false}), do: acc

    defp expect_audit(%{correlation_id: nil}, %Dsl.Expect{audit: true}) do
      raise ExUnit.AssertionError,
        message: "expect audit: no correlation id was traced in this step to find audit rows by"
    end

    defp expect_audit(%{acted: []}, %Dsl.Expect{audit: true}) do
      raise ExUnit.AssertionError,
        message:
          "expect audit: the step performed no row action, so there is no action whose audit row to find"
    end

    # Every row action of the step wrote its own row: by its action, about its
    # record, under the step's correlation id, since the step began.
    defp expect_audit(acc, %Dsl.Expect{audit: true}) do
      host = acc.run.host

      unless function_exported?(host, :assert_audit, 3) do
        raise ArgumentError,
              "#{inspect(host)} implements no assert_audit/3, so `expect audit: true` cannot be proven"
      end

      for acted <- acc.acted do
        host.assert_audit(
          acc.correlation_id,
          Map.put(acted, :since, acc.started_at),
          host_context(acc.run, acc.step.as)
        )
      end

      acc
    end

    defp expect_record(acc, %Dsl.Expect{record: nil}), do: acc

    defp expect_record(acc, %Dsl.Expect{record: {binding, expected}}) do
      record = acc.run |> binding!(binding) |> Ash.reload!(authorize?: false)

      mismatches =
        Enum.flat_map(expected, fn {attribute, value} ->
          actual = Map.get(record, attribute)

          if actual == value or to_string(actual) == to_string(value),
            do: [],
            else: ["#{attribute} is #{inspect(actual)}, expected #{inspect(value)}"]
        end)

      if mismatches != [] do
        raise ExUnit.AssertionError,
          message: "expect record #{binding}: " <> Enum.join(mismatches, "; ")
      end

      acc
    end

    # --- Figures -----------------------------------------------------------------------

    defp capture(acc, %Dsl.Figure{} = figure) do
      host = acc.run.host

      file =
        Manifest.figure_key(Atom.to_string(acc.step.name), Atom.to_string(figure.name)) <> ".png"

      selector = frame_selector(acc, figure.frame)

      masks =
        Enum.map(figure.mask, fn
          {region, opts} -> {host.mask(region), Keyword.get(opts, :width)}
          region -> {host.mask(region), nil}
        end)

      {conn, shot} =
        Figure.capture(conn(acc), Path.join(acc.run.dir, file), selector: selector, mask: masks)

      raster =
        case Raster.decode(shot.png) do
          {:ok, raster} -> raster
          {:error, reason} -> raise "figure #{figure.name} does not decode: #{reason}"
        end

      recorded =
        struct!(Manifest.Figure,
          name: Atom.to_string(figure.name),
          file: file,
          file_sha256: shot.sha256,
          raster_sha256: Raster.hash(raster),
          width: raster.width,
          height: raster.height,
          settled: shot.settled["settled"] == true,
          highlight: highlight(acc, conn, figure.highlight, selector, raster)
        )

      %{put_conn(acc, conn) | figures: [recorded | acc.figures]}
    end

    defp frame_selector(_acc, :page), do: nil
    defp frame_selector(_acc, :dialog), do: @dialog
    defp frame_selector(acc, {:row, binding}), do: row_selector(acc, binding)

    defp frame_selector(acc, {:table, table_id}) do
      manifest = manifest!(acc)

      case Enum.find(manifest.tables, &(&1.id == table_id)) do
        %{component_id: id} when is_binary(id) ->
          ~s([#{manifest.attributes.component}="#{id}"] >> visible=true)

        nil ->
          raise ArgumentError, "surface #{acc.surface} has no table #{inspect(table_id)}"

        _sectioned ->
          raise ArgumentError, "table #{inspect(table_id)} has no fixed element to frame"
      end
    end

    # The grid draws each record twice (the wide layout's row and the narrow
    # layout's card), only one of them shown.
    defp row_selector(acc, binding) do
      record = binding!(acc.run, binding)
      ~s([data-a2ui-row-id="#{record.id}"] >> visible=true)
    end

    # The highlighted row's box in the figure's pixels: relative to the frame
    # element, scaled from CSS pixels to the raster's.
    defp highlight(_acc, _conn, nil, _selector, _raster), do: nil

    defp highlight(acc, conn, {:row, binding}, selector, raster) do
      row = Figure.box(conn, row_selector(acc, binding))

      origin =
        if selector,
          do: Figure.box(conn, selector),
          else: %{x: 0, y: 0, width: raster.width}

      scale = raster.width / origin.width

      %{
        x: (row.x - origin.x) * scale,
        y: (row.y - origin.y) * scale,
        width: row.width * scale,
        height: row.height * scale
      }
    end

    # --- Lookups -----------------------------------------------------------------------

    defp row_action!(acc, id) do
      manifest = manifest!(acc)

      case Enum.find(manifest.row_actions, &(&1.id == id)) do
        nil -> raise ArgumentError, "surface #{acc.surface} has no row action #{inspect(id)}"
        action -> Map.put(action, :attributes, manifest.attributes)
      end
    end

    defp manifest!(%{run: run, surface: surface}) do
      registry = Info.surface_registry(run.module)

      case registry.surface(surface) do
        %{ui: ui} when ui != nil ->
          AshA2ui.Manifest.for_surface(ui, run.host.manifest_opts(run.locale))

        _other ->
          raise ArgumentError, "surface #{inspect(surface)} is not an A2UI surface"
      end
    end

    defp binding!(run, binding) do
      case Map.fetch(run.bindings, binding) do
        {:ok, record} -> record
        :error -> raise ArgumentError, "the world bound no record #{inspect(binding)}"
      end
    end

    defp conn(acc), do: Map.fetch!(acc.run.conns, acc.step.as)
    defp put_conn(acc, conn), do: put_in(acc, [:run, :conns, acc.step.as], conn)

    # --- The manifest ------------------------------------------------------------------

    defp skipped(journey), do: Enum.map(journey.steps, &skipped_step/1)

    defp skipped_step(step) do
      %{
        name: Atom.to_string(step.name),
        actor: Atom.to_string(step.as),
        label: nil,
        status: :skipped,
        cursor: nil,
        correlation_id: nil,
        span_ids: [],
        figures: [],
        error: nil
      }
    end

    # Each step's window closes where the next step's opened, and the last one
    # where it ended. Positions are counted over every span of the test, once
    # the run is over, so late spans are in the stream.
    defp close_windows(results, key) do
      spans = Trace.spans(key)
      cursors = for %{cursor: %Cursor{} = cursor} <- results, do: cursor
      nexts = Enum.map(Enum.drop(cursors, 1), & &1.since) ++ [nil]
      closing = Map.new(Enum.zip(cursors, nexts), fn {c, next} -> {c.label, next} end)

      Enum.map(results, fn
        %{cursor: %Cursor{} = cursor} = result ->
          cursor = if next = closing[cursor.label], do: Cursor.close(cursor, next), else: cursor
          %{result | cursor: Cursor.window(cursor, spans)}

        result ->
          result
      end)
    end

    defp manifest(run, claim, results) do
      prior_steps = prior_steps(claim.prior)

      steps =
        Enum.map(results, fn result ->
          ran = if result.status == :skipped, do: 0, else: 1

          struct!(Manifest.Step,
            name: result.name,
            actor: result.actor,
            label: result.label,
            status: result.status,
            attempts: max(Map.get(prior_steps, result.name, 0) + ran, 1),
            cursor: result.cursor,
            correlation_id: result.correlation_id,
            span_ids: result.span_ids,
            figures: result.figures,
            error: result.error
          )
        end)

      struct!(Manifest,
        run_id: claim.run_id,
        commit: commit(),
        journey: run.ir["id"],
        version: run.ir["version"],
        declaration_hash: Ir.hash(run.ir),
        locale: run.locale,
        environment: :test,
        browser: browser(run.context),
        framing: Map.new(framing(run.locale)),
        retries: claim.earlier_attempts + retries(claim.prior),
        texts: run.texts || %{},
        status: run_status(steps),
        steps: steps
      )
    end

    defp run_status(steps) do
      statuses = Enum.map(steps, & &1.status)

      cond do
        :errored in statuses -> :errored
        :failed in statuses -> :failed
        Enum.all?(statuses, &(&1 == :passed)) -> :passed
        true -> :errored
      end
    end

    defp retries(nil), do: 0
    defp retries(:unreadable), do: 1
    defp retries(%Manifest{retries: retries}), do: retries + 1

    defp prior_steps(%Manifest{steps: steps}) do
      for step <- steps, step.status != :skipped, into: %{}, do: {step.name, step.attempts}
    end

    defp prior_steps(_none), do: %{}

    defp warn_if_flaky(%Manifest{retries: retries, status: :passed} = manifest, dir)
         when retries > 0 do
      IO.puts(
        :stderr,
        "journey #{manifest.journey} (#{manifest.locale}) passed after #{retries} " <>
          "retr#{if retries == 1, do: "y", else: "ies"}: flaky, so not approvable (#{dir})"
      )
    end

    defp warn_if_flaky(_manifest, _dir), do: :ok

    defp commit do
      System.get_env("GITHUB_SHA") || git_head()
    end

    defp git_head do
      case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
        {sha, 0} -> String.trim(sha)
        _not_a_checkout -> "unknown"
      end
    rescue
      _no_git -> "unknown"
    end

    defp browser(context) do
      initializer =
        PlaywrightEx.Connection.initializer!(
          PlaywrightEx.Supervisor.Connection,
          context.browser_id
        )

      playwright = Application.get_env(:phoenix_test, :playwright, [])

      pool =
        Enum.find(playwright[:browser_pools] || [], &(&1[:id] == playwright[:browser_pool])) || []

      %{
        name: to_string(initializer[:name] || "chromium"),
        version: to_string(initializer[:version]),
        executable: pool[:executable_path] || "bundled"
      }
    end

    defp prefixed(run, label, error, dir) do
      where = if label, do: "step #{label}", else: "before the first step"
      prefix = "journey #{run.journey.name} (#{run.locale}), #{where}: "
      suffix = "\n(run manifest and figures in #{Path.relative_to_cwd(dir)})"

      message =
        case error do
          %ExUnit.AssertionError{message: message} -> message
          other -> "#{inspect(other.__struct__)}: " <> Exception.message(other)
        end

      %ExUnit.AssertionError{message: prefix <> message <> suffix}
    end
  end
end
