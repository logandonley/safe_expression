defmodule SafeExpressionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest SafeExpression

  alias SafeExpression, as: Expression

  describe "values and bindings" do
    test "a bare path returns caller-provided terms unchanged" do
      values = [
        {:queued, 42},
        %{nested: :value},
        [:a, :list],
        :an_atom,
        fn -> :result end
      ]

      for value <- values do
        assert Expression.eval("value", %{"value" => value}) == {:ok, value}
      end
    end

    test "paths use string keys only" do
      assert Expression.eval("value", %{value: 42}) == {:ok, nil}
      assert Expression.eval("nested.value", %{"nested" => %{value: 42}}) == {:ok, nil}
    end

    test "dotted paths walk nested maps" do
      assert Expression.eval("user.profile.age", %{
               "user" => %{"profile" => %{"age" => 21}}
             }) == {:ok, 21}
    end

    test "missing, non-map, and explicitly nil paths all resolve to nil" do
      assert Expression.eval("user.age", %{}) == {:ok, nil}
      assert Expression.eval("user.age", %{"user" => "not a map"}) == {:ok, nil}
      assert Expression.eval("user.age", %{"user" => %{"age" => nil}}) == {:ok, nil}
    end

    test "identifiers accept underscores and trailing digits without consuming keyword prefixes" do
      bindings = %{"_private2" => 2, "true_value1" => 1, "nil_value" => nil}

      assert Expression.eval("_private2 == 2", bindings) == {:ok, true}
      assert Expression.eval("true_value1 == 1", bindings) == {:ok, true}
      assert Expression.eval("nil_value == null", bindings) == {:ok, true}
    end
  end

  describe "literals and equality" do
    test "number, boolean, null, and nil literals retain their native values" do
      assert Expression.eval("12", %{}) == {:ok, 12}
      assert Expression.eval("12.5", %{}) == {:ok, 12.5}
      assert Expression.eval("true", %{}) == {:ok, true}
      assert Expression.eval("false", %{}) == {:ok, false}
      assert Expression.eval("null", %{}) == {:ok, nil}
      assert Expression.eval("nil", %{}) == {:ok, nil}
    end

    test "single and double quoted strings support escaped delimiters" do
      assert Expression.eval(~S("double \" quote"), %{}) == {:ok, ~s(double " quote)}
      assert Expression.eval(~S('single \' quote'), %{}) == {:ok, "single ' quote"}
    end

    test "string literals preserve Unicode" do
      assert Expression.eval(~s("héllo 世界"), %{}) == {:ok, "héllo 世界"}
    end

    test "backslash escapes the next character without interpreting escape sequences" do
      assert Expression.eval(~S("a\nb"), %{}) == {:ok, "anb"}
      assert Expression.eval(~S("a\\b"), %{}) == {:ok, "a\\b"}
    end

    test "equality uses Elixir semantics without coercion" do
      assert Expression.eval("1 == 1.0", %{}) == {:ok, true}
      assert Expression.eval(~s(value == "5"), %{"value" => 5}) == {:ok, false}
      assert Expression.eval("left != right", %{"left" => :a, "right" => :b}) == {:ok, true}
    end
  end

  describe "operators and precedence" do
    test "every comparison operator evaluates numbers" do
      cases = [
        {"value < 5", 4, true},
        {"value > 5", 4, false},
        {"value <= 5", 5, true},
        {"value >= 5", 5, true},
        {"value == 5", 5, true},
        {"value != 5", 5, false}
      ]

      for {source, value, expected} <- cases do
        assert Expression.eval(source, %{"value" => value}) == {:ok, expected}
      end
    end

    test "ordering compares integers and floats" do
      assert Expression.eval("value >= 2.5", %{"value" => 3}) == {:ok, true}
      assert Expression.eval("value < 3", %{"value" => 2.5}) == {:ok, true}
    end

    test "precedence is unary, ordering, equality, and, then or" do
      assert Expression.eval("!true == false", %{}) == {:ok, true}
      assert Expression.eval("1 < 2 == true", %{}) == {:ok, true}
      assert Expression.eval("true == true && false", %{}) == {:ok, false}
      assert Expression.eval("false && true || true", %{}) == {:ok, true}
    end

    test "parentheses override precedence" do
      bindings = %{"a" => false, "b" => true, "c" => false}

      assert Expression.eval("a || b && c", bindings) == {:ok, false}
      assert Expression.eval("(a || b) && c", bindings) == {:ok, false}
      assert Expression.eval("a || (b && !c)", bindings) == {:ok, true}
    end

    test "unary not can repeat" do
      assert Expression.eval("!!true", %{}) == {:ok, true}
      assert Expression.eval("!!!false", %{}) == {:ok, true}
    end

    test "boolean operators short-circuit" do
      assert Expression.eval("false && value", %{"value" => 5}) == {:ok, false}
      assert Expression.eval("true || value", %{"value" => 5}) == {:ok, true}
    end

    test "required boolean operands return exact type errors" do
      assert Expression.eval("1 && true", %{}) == {:error, {:not_boolean, 1}}
      assert Expression.eval("true && 1", %{}) == {:error, {:not_boolean, 1}}
      assert Expression.eval("false || 1", %{}) == {:error, {:not_boolean, 1}}
      assert Expression.eval("!1", %{}) == {:error, {:not_boolean, 1}}
    end

    test "space, tab, newline, and carriage return are whitespace" do
      assert Expression.eval(" \ttrue\n&&\r!false ", %{}) == {:ok, true}
    end
  end

  describe "ordering type errors" do
    test "every nonnumeric value category is rejected" do
      values = ["text", true, nil, %{}, [], {:tuple, 1}, :atom]

      for value <- values do
        assert Expression.eval("value < 1", %{"value" => value}) ==
                 {:error, {:not_comparable, :lt, value, 1}}
      end
    end

    test "the error identifies each ordering operator and both operands" do
      cases = [
        {"left < right", :lt},
        {"left > right", :gt},
        {"left <= right", :lte},
        {"left >= right", :gte}
      ]

      for {source, operator} <- cases do
        assert Expression.eval(source, %{"left" => 1, "right" => "two"}) ==
                 {:error, {:not_comparable, operator, 1, "two"}}
      end
    end
  end

  describe "malformed input" do
    test "empty and dangling expressions return unexpected end" do
      for source <- ["", "!", "1 ==", "true &&", "false ||", "("] do
        assert Expression.eval(source, %{}) == {:error, :unexpected_end}
      end
    end

    test "unexpected primary and leftover tokens return a normalized error" do
      assert Expression.eval(")", %{}) == {:error, :unexpected_token}
      assert Expression.eval("true)", %{}) == {:error, :unexpected_token}
      assert Expression.eval("a == 1 b", %{"a" => 1}) == {:error, :unexpected_token}
    end

    test "unclosed parentheses return the documented error" do
      assert Expression.eval("(a == 1", %{"a" => 1}) ==
               {:error, :missing_closing_parenthesis}
    end

    test "unknown and malformed one-character operators identify the character" do
      for {source, character} <- [
            {"a @ 1", "@"},
            {"-1", "-"},
            {"a = 1", "="},
            {"true & false", "&"},
            {"true | false", "|"}
          ] do
        assert Expression.eval(source, %{"a" => 1}) ==
                 {:error, {:unexpected_character, character}}
      end
    end

    test "unclosed strings return the documented error" do
      assert Expression.eval(~S("unfinished), %{}) == {:error, :unterminated_string}
      assert Expression.eval(~S('unfinished), %{}) == {:error, :unterminated_string}
    end

    test "repeated decimal points return the malformed number" do
      assert Expression.eval("1.2.3", %{}) == {:error, {:invalid_number, "1.2.3"}}
      assert Expression.eval("1..2", %{}) == {:error, {:invalid_number, "1..2"}}
    end

    test "a path cannot end with a dot or contain an empty segment" do
      assert Expression.eval("a.", %{}) == {:error, :trailing_dot}
      assert Expression.eval("a..b", %{}) == {:error, :trailing_dot}
    end

    test "invalid UTF-8 is always normalized" do
      assert Expression.eval(<<255>>, %{}) == {:error, :invalid_utf8}
      assert Expression.eval(<<"name", 255>>, %{}) == {:error, :invalid_utf8}
      assert Expression.eval(<<"\"", 255>>, %{}) == {:error, :invalid_utf8}
      assert Expression.eval(<<"\"\\", 255>>, %{}) == {:error, :invalid_utf8}
    end
  end

  describe "argument and safety contract" do
    test "invalid argument types raise FunctionClauseError" do
      assert_raise FunctionClauseError, fn -> apply(Expression, :eval, [:not_binary, %{}]) end
      assert_raise FunctionClauseError, fn -> apply(Expression, :eval, ["true", []]) end
    end

    test "function-call syntax is not executable" do
      assert Expression.eval("System.halt(1)", %{}) == {:error, :unexpected_token}
      assert Expression.eval(~S|File.read!("/etc/passwd")|, %{}) == {:error, :unexpected_token}
    end
  end

  property "arbitrary binaries never raise or escape the documented result contract" do
    check all(source <- binary(), max_runs: 500) do
      case Expression.eval(source, %{}) do
        {:ok, _value} ->
          :ok

        {:error, reason} ->
          assert documented_reason?(reason)
      end
    end
  end

  property "non-negative integer ordering agrees with Elixir" do
    check all(
            left <- integer(0..1_000_000),
            right <- integer(0..1_000_000)
          ) do
      assert Expression.eval("value < #{right}", %{"value" => left}) == {:ok, left < right}
    end
  end

  defp documented_reason?(reason)
       when reason in [
              :invalid_utf8,
              :unterminated_string,
              :unexpected_end,
              :missing_closing_parenthesis,
              :trailing_dot,
              :unexpected_token
            ],
       do: true

  defp documented_reason?({:unexpected_character, character}), do: is_binary(character)
  defp documented_reason?({:invalid_number, number}), do: is_binary(number)
  defp documented_reason?({:not_boolean, _value}), do: true

  defp documented_reason?({:not_comparable, operator, _left, _right}),
    do: operator in [:lt, :gt, :lte, :gte]

  defp documented_reason?(_reason), do: false
end
