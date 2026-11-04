defmodule AshEnterprise.L10n.GeneratorTest do
  @moduledoc """
  The design-time catalog generator (ADR 0060, section 3) against a fake
  translator. No model is called: the fake answers from a function the test
  gives it, which is how every malformed answer below is produced.
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.L10n.Generator

  defmodule Fake do
    @moduledoc false
    @behaviour AshEnterprise.L10n.Translator

    # `opts[:answer]` builds the answer from the request; every request is
    # sent to the test process so it can inspect the batches.
    @impl true
    def translate(request, opts) do
      send(opts[:test], {:request, request})
      opts[:answer].(request)
    end
  end

  @po """
  msgid ""
  msgstr ""
  "Language: fr\\n"
  "Plural-Forms: nplurals=2; plural=(n > 1);\\n"

  #: lib/a.ex:1
  msgid "Admin"
  msgstr ""

  #: lib/a.ex:2
  msgid "Today"
  msgstr "Aujourd'hui"

  #: lib/a.ex:3
  msgid "No app matches “%{query}”."
  msgstr ""

  #: lib/a.ex:4
  msgid "%{count} linked"
  msgid_plural "%{count} linked"
  msgstr[0] ""
  msgstr[1] ""
  """

  @french %{
    "Admin" => "Administration",
    "No app matches “%{query}”." => "Aucune application ne correspond à « %{query} »."
  }

  # A well-behaved translator: one answer per item, echoing id and msgid.
  defp good(request) do
    {:ok,
     %{
       "translations" =>
         Enum.map(request.items, fn
           %{msgid_plural: nil} = item ->
             %{
               "id" => item.id,
               "msgid" => item.msgid,
               "msgstr" => Map.fetch!(@french, item.msgid)
             }

           item ->
             %{
               "id" => item.id,
               "msgid" => item.msgid,
               "msgstr_plural" => ["%{count} lié", "%{count} liés"]
             }
         end)
     }}
  end

  defp run(content, answer, opts \\ []) do
    Generator.generate(
      content,
      [locale: "fr", translator: Fake, translator_opts: [test: self(), answer: answer]] ++ opts
    )
  end

  # The good answer for every item, then `fun` applied to the list.
  defp tampered(fun) do
    fn request ->
      {:ok, %{"translations" => list}} = good(request)
      {:ok, %{"translations" => fun.(list)}}
    end
  end

  test "fills only the empty messages and keeps the rest byte for byte" do
    assert {:ok, out, %{translated: 3, batches: 1}} = run(@po, &good/1)

    assert out =~ ~s(msgid "Admin"\nmsgstr "Administration")
    assert out =~ ~s(msgstr "Aujourd'hui")
    assert out =~ ~s(msgstr[0] "%{count} lié"\nmsgstr[1] "%{count} liés")
    assert {:ok, _po} = Expo.PO.parse_string(out)

    assert_received {:request, request}

    assert Enum.map(request.items, & &1.msgid) == [
             "Admin",
             "No app matches “%{query}”.",
             "%{count} linked"
           ]

    assert request.nplurals == 2
    assert hd(request.items).comments == ["lib/a.ex:1"]
  end

  test "is idempotent: its own output, and a full catalog, go back unchanged without a call" do
    {:ok, once, _stats} = run(@po, &good/1)
    assert_received {:request, _request}

    assert {:ok, ^once, %{translated: 0, batches: 0}} = run(once, &good/1)
    refute_received {:request, _request}
  end

  test "batches are bounded and in file order" do
    content =
      Enum.reduce(1..7, "msgid \"\"\nmsgstr \"\"\n", fn n, acc ->
        acc <> "\nmsgid \"Item #{n}\"\nmsgstr \"\"\n"
      end)

    answer = fn request ->
      {:ok,
       %{
         "translations" =>
           Enum.map(request.items, &%{"id" => &1.id, "msgid" => &1.msgid, "msgstr" => "Élément"})
       }}
    end

    assert {:ok, _out, %{translated: 7, batches: 3}} = run(content, answer, batch_size: 3)

    batches =
      for _n <- 1..3 do
        assert_received {:request, %{items: items}}
        Enum.map(items, & &1.msgid)
      end

    assert batches == [
             ["Item 1", "Item 2", "Item 3"],
             ["Item 4", "Item 5", "Item 6"],
             ["Item 7"]
           ]

    assert {:error, [{nil, "batch size must be 1..50, got 500"}]} =
             run(content, answer, batch_size: 500)
  end

  test "the glossary and domain reach the translator" do
    run(@po, &good/1, glossary: %{"Today" => "Aujourd'hui"}, domain: "default")
    assert_received {:request, %{glossary: %{"Today" => "Aujourd'hui"}, domain: "default"}}
  end

  describe "a malformed answer is refused whole, and nothing is returned" do
    test "not the expected shape" do
      for answer <- [%{}, "translations", [1, 2], %{"translations" => "none"}, nil] do
        assert {:error, [{nil, reason}]} = run(@po, fn _ -> {:ok, answer} end)
        assert reason =~ "answer is not"
      end
    end

    test "a translator error" do
      assert {:error, [{nil, "translator failed: timeout"}]} =
               run(@po, fn _ -> {:error, "timeout"} end)

      assert {:error, [{nil, "translator returned :oops"}]} = run(@po, fn _ -> :oops end)
    end

    test "a missing translation" do
      assert {:error, problems} = run(@po, tampered(&tl/1))
      assert {"Admin", "missing translation"} in problems
    end

    test "an invented id" do
      extra = %{"id" => "99", "msgid" => "Invented", "msgstr" => "Inventé"}
      assert {:error, problems} = run(@po, tampered(&(&1 ++ [extra])))
      assert {"99", "invented id: not in this batch"} in problems
    end

    test "an invented msgid" do
      assert {:error, problems} =
               run(
                 @po,
                 tampered(fn [first | rest] -> [%{first | "msgid" => "Administrator"} | rest] end)
               )

      assert {"Admin", "invented msgid: does not match"} in problems
    end

    test "a duplicate" do
      assert {:error, problems} = run(@po, tampered(fn [first | _] = list -> list ++ [first] end))
      assert {"Admin", "duplicate translation"} in problems
    end

    test "an empty or non-string translation" do
      for value <- ["", "   ", nil, 42, ["Administration"]] do
        assert {:error, problems} =
                 run(
                   @po,
                   tampered(fn [first | rest] -> [%{first | "msgstr" => value} | rest] end)
                 )

        assert Enum.any?(problems, fn {msgid, reason} ->
                 msgid == "Admin" and
                   reason in ["empty translation", "translation is not a string"]
               end)
      end
    end

    test "a dropped, renamed or added placeholder" do
      for value <- [
            "Aucune application ne correspond.",
            "Aucune application ne correspond à %{requête}.",
            "Aucune application ne correspond à %{query} (%{count})."
          ] do
        assert {:error, [{"No app matches “%{query}”.", reason}]} =
                 run(
                   @po,
                   tampered(fn list ->
                     Enum.map(list, fn
                       %{"msgid" => "No app matches" <> _} = answer ->
                         %{answer | "msgstr" => value}

                       answer ->
                         answer
                     end)
                   end)
                 )

        assert reason =~ "placeholders differ"
      end
    end

    test "the wrong plural shape" do
      plural = fn value ->
        tampered(fn list ->
          Enum.map(list, fn
            %{"msgstr_plural" => _} = answer ->
              Map.merge(Map.delete(answer, "msgstr_plural"), value)

            answer ->
              answer
          end)
        end)
      end

      assert {:error, [{"%{count} linked", "3 plural forms, the locale has 2"}]} =
               run(@po, plural.(%{"msgstr_plural" => ["a %{count}", "b %{count}", "c %{count}"]}))

      assert {:error, [{"%{count} linked", "singular answer for a plural message"}]} =
               run(@po, plural.(%{"msgstr" => "%{count} lié"}))

      assert {:error, [{"%{count} linked", "empty translation"}]} =
               run(@po, plural.(%{"msgstr_plural" => ["%{count} lié", ""]}))

      assert {:error, [{"%{count} linked", reason}]} =
               run(@po, plural.(%{"msgstr_plural" => ["%{n} lié", "%{count} liés"]}))

      assert reason =~ "placeholders differ"

      # `%{count}` may be left out of a form ("un lié"); nothing else may be.
      assert {:ok, _out, _stats} =
               run(@po, plural.(%{"msgstr_plural" => ["un lié", "%{count} liés"]}))
    end

    test "a plural answer for a singular message" do
      assert {:error, problems} =
               run(
                 @po,
                 tampered(fn [first | rest] ->
                   [Map.put(Map.delete(first, "msgstr"), "msgstr_plural", ["a", "b"]) | rest]
                 end)
               )

      assert {"Admin", "plural answer for a singular message"} in problems
    end
  end

  test "an invalid PO is refused before anything is asked" do
    assert {:error, [{nil, "invalid PO: " <> _}]} = run("msgid \"unterminated\n", &good/1)
    refute_received {:request, _request}
  end

  test "a catalog without a Plural-Forms header takes the locale's rule" do
    content =
      "msgid \"%{count} file\"\nmsgid_plural \"%{count} files\"\nmsgstr[0] \"\"\nmsgstr[1] \"\"\n"

    answer = fn %{items: [item], nplurals: 2} ->
      {:ok,
       %{
         "translations" => [
           %{
             "id" => item.id,
             "msgid" => item.msgid,
             "msgstr_plural" => ["%{count} fichier", "%{count} fichiers"]
           }
         ]
       }}
    end

    assert {:ok, out, %{translated: 1}} = run(content, answer)
    assert out =~ ~s(msgstr[1] "%{count} fichiers")
  end
end
