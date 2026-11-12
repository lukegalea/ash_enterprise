defmodule AshEnterprise.Telemetry.SanitizeTest do
  use ExUnit.Case, async: true

  alias AshEnterprise.Telemetry.Sanitize

  describe "stacktrace/1" do
    test "an args-bearing frame keeps only its arity" do
      frame = {Mod, :fun, [%{"password" => "hunter2"}, :socket], [file: ~c"a.ex", line: 1]}

      assert Sanitize.stacktrace([frame]) == [{Mod, :fun, 2, [file: ~c"a.ex", line: 1]}]
    end

    test "an anonymous-function frame keeps only its arity" do
      fun = fn _one -> :ok end
      assert [{^fun, 1, []}] = Sanitize.stacktrace([{fun, [%{"secret" => 1}], []}])
    end

    test "frames that already have an arity are unchanged" do
      frames = [{Mod, :fun, 2, []}]
      assert Sanitize.stacktrace(frames) == frames
    end

    test "formatted output carries no argument values" do
      formatted =
        Exception.format_stacktrace(Sanitize.stacktrace([{Mod, :fun, ["hunter2"], []}]))

      refute formatted =~ "hunter2"
      assert formatted =~ "Mod.fun/1"
    end

    test "anything that is not a list is an empty stacktrace" do
      assert Sanitize.stacktrace(nil) == []
      assert Sanitize.stacktrace(:nope) == []
    end
  end

  describe "exception/1" do
    test "exceptions whose message prints a runtime value lose that value" do
      secret = %{"password" => "hunter2"}

      for exception <- [
            %MatchError{term: secret},
            %CaseClauseError{term: secret},
            %WithClauseError{term: secret},
            %TryClauseError{term: secret},
            %BadMapError{term: secret},
            %BadBooleanError{term: secret, operator: :and},
            %BadFunctionError{term: secret},
            %KeyError{key: :a, term: secret},
            %Protocol.UndefinedError{protocol: Enumerable, value: secret}
          ] do
        message = exception |> Sanitize.exception() |> Exception.message()
        refute message =~ "hunter2", "#{inspect(exception.__struct__)} leaked: #{message}"
      end
    end

    test "other exceptions are unchanged" do
      exception = RuntimeError.exception("boom")
      assert Sanitize.exception(exception) == exception
    end
  end

  describe "truncate/2" do
    test "never cuts a multi-byte character in half" do
      # "é" is two bytes; a cut at 2 lands inside it.
      assert Sanitize.truncate("aé", 2) == "a"
      assert Sanitize.truncate("日本語", 4) == "日"
      assert Sanitize.truncate("🙂🙂", 5) == "🙂"
    end

    test "the result encodes as JSON at every cut point" do
      value = String.duplicate("日本語🙂é", 20)

      for max <- 0..byte_size(value) do
        result = Sanitize.truncate(value, max)
        assert String.valid?(result)
        assert byte_size(result) <= max
        assert {:ok, _json} = Jason.encode(result)
      end
    end

    test "short and ASCII values are untouched" do
      assert Sanitize.truncate("abc", 10) == "abc"
      assert Sanitize.truncate("abcdef", 3) == "abc"
    end

    test "an invalid input keeps its valid prefix" do
      assert Sanitize.truncate(<<"ab", 0xFF, "cd">>, 10) == "ab"
    end
  end

  describe "path/1" do
    test "a token-like segment is replaced" do
      assert Sanitize.path("/password-reset/Xq3v9TzK1mNp7RwB2yLc") == "/password-reset/:token"

      assert Sanitize.path(
               "/auth/magic/eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOjF9.c2lnbmF0dXJlMTIz/sign-in"
             ) ==
               "/auth/magic/:token/sign-in"
    end

    test "words, slugs and numeric ids keep their shape" do
      assert Sanitize.path("/pages/a-very-long-readable-page-slug/42") ==
               "/pages/a-very-long-readable-page-slug/42"

      assert Sanitize.path("/") == "/"
      assert Sanitize.path("") == ""
    end

    test "a short segment with letters and digits is not a token" do
      assert Sanitize.path("/v2/items/abc123") == "/v2/items/abc123"
    end
  end

  describe "query/1" do
    test "keeps the keys and drops every value" do
      assert Sanitize.query("reset_token=abc&_csrf_token=zzz&q=acme") ==
               "reset_token=[Filtered]&_csrf_token=[Filtered]&q=[Filtered]"
    end

    test "a segment with no key could be the secret itself, so it is filtered" do
      assert Sanitize.query("flag&a=1") == "[Filtered]&a=[Filtered]"
    end

    test "a key that does not look like a parameter name is filtered" do
      assert Sanitize.query("jane%40acme.test=1") == "[Filtered]=[Filtered]"
    end

    test "an empty query stays empty" do
      assert Sanitize.query("") == ""
    end

    test "the output is bounded" do
      result = Sanitize.query(Enum.map_join(1..500, "&", &"#{String.duplicate("k", 500)}#{&1}=v"))
      assert byte_size(result) <= 1_024
      assert String.valid?(result)
    end
  end

  test "a clause error loses the arguments Exception.format/3 would blame" do
    exception =
      Exception.normalize(:error, :function_clause, [
        {Kernel, :not_a_function, [%{"secret" => "blamed-secret"}], []}
      ])

    sanitized = Sanitize.exception(exception)
    refute Exception.format(:error, sanitized, []) =~ "blamed-secret"
  end

  test "an exit reason keeps its tag only" do
    assert Sanitize.reason_label({:bad_state, "secret"}) == ":bad_state"
    assert Sanitize.reason_label(:normal) == ":normal"
    assert Sanitize.reason_label({}) == "unknown reason"
    assert Sanitize.reason_label("secret") == "unknown reason"
  end
end
