defmodule AshEnterprise.AgentSpike.S8JcsTest do
  @moduledoc """
  Spike S8: an RFC 8785 (JCS) encoder for digests shown outside the system
  (approval details, release manifests).

  **Question.** Is there a maintained Hex package that produces RFC 8785
  output, checked against the RFC's own published vectors, so the platform
  need not write one? The house canonical encoders are canonical but not JCS.

  **Packages found (hex.pm, 2026-10-23).** `rfc8785` 1.0.0 (2026-07) refuses
  to compile below Erlang/OTP 29; this application runs OTP 27, so it cannot
  be used yet. `jcs` 0.2.0 (2025-03, Apache-2.0, depends only on `jason`) is
  the candidate tested here, as a test-only dependency.

  **Result: holds for the RFC vectors, with one caveat for the caller.**
  `jcs` reproduces the RFC's §3.2.2–§3.2.4 example byte for byte, the
  property-sorting vector of §3.2.3 and every finite sample of Appendix B.
  NaN and Infinity cannot reach it (BEAM floats cannot represent them), and
  input outside the JSON mapping (structs, other atoms) raises rather than
  encoding something.

  The caveat, asserted below as a recorded divergence: an Elixir *integer*
  outside ±2^53 is written with all its digits, while JCS treats every number
  as an IEEE-754 double (`2**68` is `295147905179352830000`). The digest
  helper that adopts this package must therefore refuse integers outside
  ±2^53, or carry them as strings (RFC 8785 Appendix D), before encoding.
  Promoting `jcs` from a test dependency to a runtime one is the adopting
  ticket's decision; the fallback is a small in-house encoder tested against
  these same vectors.
  """

  use ExUnit.Case, async: true

  # RFC 8785 §3.2.2: the parsed sample.
  @sample ~S"""
  {
    "numbers": [333333333.33333329, 1E30, 4.50,
                2e-3, 0.000000000000000000000000001],
    "string": "\u20ac$\u000F\u000aA'\u0042\u0022\u005c\\\"\/",
    "literals": [null, true, false]
  }
  """

  # RFC 8785 §3.2.4: the canonical bytes of that sample.
  @sample_bytes """
  7b 22 6c 69 74 65 72 61 6c 73 22 3a 5b 6e 75 6c 6c 2c 74 72
  75 65 2c 66 61 6c 73 65 5d 2c 22 6e 75 6d 62 65 72 73 22 3a
  5b 33 33 33 33 33 33 33 33 33 2e 33 33 33 33 33 33 33 2c 31
  65 2b 33 30 2c 34 2e 35 2c 30 2e 30 30 32 2c 31 65 2d 32 37
  5d 2c 22 73 74 72 69 6e 67 22 3a 22 e2 82 ac 24 5c 75 30 30
  30 66 5c 6e 41 27 42 5c 22 5c 5c 5c 5c 5c 22 2f 22 7d
  """

  # RFC 8785 Appendix B, the finite samples: IEEE 754 bits -> JSON text.
  @numbers [
    {"0000000000000000", "0"},
    {"8000000000000000", "0"},
    {"0000000000000001", "5e-324"},
    {"8000000000000001", "-5e-324"},
    {"7fefffffffffffff", "1.7976931348623157e+308"},
    {"ffefffffffffffff", "-1.7976931348623157e+308"},
    {"4340000000000000", "9007199254740992"},
    {"c340000000000000", "-9007199254740992"},
    {"4430000000000000", "295147905179352830000"},
    {"44b52d02c7e14af5", "9.999999999999997e+22"},
    {"44b52d02c7e14af6", "1e+23"},
    {"44b52d02c7e14af7", "1.0000000000000001e+23"},
    {"444b1ae4d6e2ef4e", "999999999999999700000"},
    {"444b1ae4d6e2ef4f", "999999999999999900000"},
    {"444b1ae4d6e2ef50", "1e+21"},
    {"3eb0c6f7a0b5ed8c", "9.999999999999997e-7"},
    {"3eb0c6f7a0b5ed8d", "0.000001"},
    {"41b3de4355555553", "333333333.3333332"},
    {"41b3de4355555554", "333333333.33333325"},
    {"41b3de4355555555", "333333333.3333333"},
    {"41b3de4355555556", "333333333.3333334"},
    {"41b3de4355555557", "333333333.33333343"},
    {"becbf647612f3696", "-0.0000033333333333333333"},
    {"43143ff3c1cb0959", "1424953923781206.2"}
  ]

  defp float_from_bits(hex) do
    <<value::float-64>> = Base.decode16!(hex, case: :lower)
    value
  end

  test "the §3.2.2 sample canonicalizes to the §3.2.4 bytes" do
    expected = @sample_bytes |> String.replace(~r/\s+/, "") |> Base.decode16!(case: :lower)
    assert Jcs.encode(Jason.decode!(@sample)) == expected
  end

  test "every finite Appendix B number serializes as the RFC says" do
    for {bits, expected} <- @numbers do
      assert Jcs.encode(float_from_bits(bits)) == expected, "IEEE 754 #{bits}"
    end
  end

  test "NaN and Infinity cannot be built as BEAM floats, so cannot reach the encoder" do
    for bits <- ["7fffffffffffffff", "7ff0000000000000"] do
      assert_raise MatchError, fn -> float_from_bits(bits) end
    end
  end

  test "object properties sort by UTF-16 code units (§3.2.3)" do
    input = %{
      "\u20ac" => "Euro Sign",
      "\r" => "Carriage Return",
      "\ufb33" => "Hebrew Letter Dalet With Dagesh",
      "1" => "One",
      "\u{1F600}" => "Emoji: Grinning Face",
      "\u0080" => "Control",
      "\u00f6" => "Latin Small Letter O With Diaeresis"
    }

    order =
      ~r/":"([^"]+)"/
      |> Regex.scan(Jcs.encode(input), capture: :all_but_first)
      |> List.flatten()

    assert order == [
             "Carriage Return",
             "One",
             "Control",
             "Latin Small Letter O With Diaeresis",
             "Euro Sign",
             "Emoji: Grinning Face",
             "Hebrew Letter Dalet With Dagesh"
           ]
  end

  test "terms outside the JSON mapping raise instead of encoding" do
    assert_raise ArgumentError, fn -> Jcs.encode(%{"at" => ~U[2026-10-23 12:00:00Z]}) end
    assert_raise ArgumentError, fn -> Jcs.encode(%{"kind" => :clinic}) end
  end

  test "recorded divergence: integers beyond 2^53 keep every digit instead of a double's" do
    two_68 = Integer.pow(2, 68)

    # JCS, through a double: what the RFC's Appendix B gives for 2**68.
    assert Jcs.encode(two_68 * 1.0) == "295147905179352830000"

    # The package, given an integer: all digits. Not JCS; the caller must
    # refuse or stringify such integers before hashing.
    assert Jcs.encode(two_68) == "295147905179352825856"
    refute Jcs.encode(two_68) == Jcs.encode(two_68 * 1.0)

    # Within ±2^53 an integer and its double agree, as the RFC requires.
    assert Jcs.encode(9_007_199_254_740_992) == Jcs.encode(9_007_199_254_740_992.0)
  end
end
