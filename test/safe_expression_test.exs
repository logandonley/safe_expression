defmodule SafeExpressionTest do
  @moduledoc """
  Contract tests for the constrained, safe expression language: comparisons,
  boolean logic, and dotted field access over a bindings map, with no arbitrary
  code.
  """
  use ExUnit.Case, async: true

  alias SafeExpression, as: Expression

  describe "comparisons over bindings" do
    test "a numeric comparison resolves an identifier from the bindings" do
      assert Expression.eval("count > 5", %{"count" => 10}) == {:ok, true}
    end

    test "each ordering operator compares numbers" do
      assert Expression.eval("n < 5", %{"n" => 3}) == {:ok, true}
      assert Expression.eval("n <= 3", %{"n" => 3}) == {:ok, true}
      assert Expression.eval("n >= 4", %{"n" => 3}) == {:ok, false}
      assert Expression.eval("n > 3", %{"n" => 3}) == {:ok, false}
    end

    test "ints and floats compare across types" do
      assert Expression.eval("n >= 2.5", %{"n" => 3}) == {:ok, true}
    end

    test "equality is structural and type-aware across any value" do
      assert Expression.eval(~s(name == "Ada"), %{"name" => "Ada"}) == {:ok, true}
      assert Expression.eval("flag != true", %{"flag" => false}) == {:ok, true}
      # A number and its string form are not equal — no coercion.
      assert Expression.eval(~s(n == "5"), %{"n" => 5}) == {:ok, false}
    end

    test "Elixir numeric equality treats equivalent integers and floats as equal" do
      assert Expression.eval("1 == 1.0", %{}) == {:ok, true}
    end

    test "ordering a non-number is a type error, not a crash" do
      assert {:error, {:not_comparable, :gt, "Ada", 5}} =
               Expression.eval("name > 5", %{"name" => "Ada"})
    end
  end

  describe "literals" do
    test "string literals accept single or double quotes" do
      assert Expression.eval(~s(x == 'hi'), %{"x" => "hi"}) == {:ok, true}
      assert Expression.eval(~s(x == "hi"), %{"x" => "hi"}) == {:ok, true}
    end

    test "backslash escapes the next character without interpreting escape sequences" do
      assert Expression.eval(~S(value == "a\nb"), %{"value" => "anb"}) == {:ok, true}
      assert Expression.eval(~S(value == "a\nb"), %{"value" => "a\nb"}) == {:ok, false}
    end

    test "null compares equal to a missing field — presence testing" do
      assert Expression.eval("x == null", %{}) == {:ok, true}
      assert Expression.eval("x != null", %{"x" => 1}) == {:ok, true}
    end

    test "nil is an alias for null" do
      assert Expression.eval("x == nil", %{}) == {:ok, true}
      assert Expression.eval("nil == null", %{}) == {:ok, true}
    end
  end

  describe "boolean logic" do
    test "&& and || combine comparisons" do
      bindings = %{"count" => 10, "kind" => "webhook"}
      assert Expression.eval(~s(count > 5 && kind == "webhook"), bindings) == {:ok, true}
      assert Expression.eval(~s(count > 50 || kind == "webhook"), bindings) == {:ok, true}
      assert Expression.eval(~s(count > 50 && kind == "webhook"), bindings) == {:ok, false}
    end

    test "! negates a boolean" do
      assert Expression.eval("!active", %{"active" => false}) == {:ok, true}
    end

    test "&& and || short-circuit before evaluating the right operand" do
      assert Expression.eval("false && value", %{"value" => 5}) == {:ok, false}
      assert Expression.eval("true || value", %{"value" => 5}) == {:ok, true}
    end

    test "&& binds tighter than ||" do
      # false || (true && false) -> false ; not (false || true) && false
      assert Expression.eval("a || b && c", %{"a" => false, "b" => true, "c" => false}) ==
               {:ok, false}
    end

    test "parentheses override precedence" do
      assert Expression.eval("(a || b) && c", %{"a" => false, "b" => true, "c" => false}) ==
               {:ok, false}

      assert Expression.eval("(a || b) && c", %{"a" => false, "b" => true, "c" => true}) ==
               {:ok, true}
    end

    test "boolean logic on a non-boolean is a type error" do
      assert {:error, {:not_boolean, 5}} = Expression.eval("n && true", %{"n" => 5})
    end
  end

  describe "field access" do
    test "a dotted path walks into nested maps" do
      assert Expression.eval("user.age >= 18", %{"user" => %{"age" => 21}}) == {:ok, true}
    end

    test "a path through a missing or non-map node resolves to nil" do
      assert Expression.eval("user.age == null", %{"user" => nil}) == {:ok, true}
      assert Expression.eval("a.b.c == null", %{}) == {:ok, true}
    end

    test "a bare boolean field is a valid predicate" do
      assert Expression.eval("active", %{"active" => true}) == {:ok, true}
    end
  end

  describe "malformed input returns an error" do
    test "an empty expression" do
      assert {:error, _} = Expression.eval("", %{})
    end

    test "a dangling operator" do
      assert {:error, _} = Expression.eval("count >", %{"count" => 1})
    end

    test "an unclosed parenthesis" do
      assert {:error, _} = Expression.eval("(a == 1", %{"a" => 1})
    end

    test "leftover tokens after a complete expression" do
      assert {:error, {:unexpected_tokens, [{:ident, "b"}]}} =
               Expression.eval("a == 1 b", %{"a" => 1})
    end

    test "an unknown character" do
      assert {:error, _} = Expression.eval("a @ 1", %{"a" => 1})
    end

    test "a negative numeric literal is rejected as an unexpected character" do
      assert Expression.eval("-1", %{}) == {:error, {:unexpected_char, "-"}}
    end

    test "an unclosed string is rejected" do
      assert Expression.eval(~S("unfinished), %{}) == {:error, :unterminated_string}
    end

    test "a malformed numeric literal is rejected" do
      assert Expression.eval("1.2.3", %{}) == {:error, {:bad_number, "1.2.3"}}
    end

    test "a path cannot end with a dot" do
      assert Expression.eval("a.", %{}) == {:error, :trailing_dot}
    end
  end

  describe "argument contract" do
    test "invalid source and bindings types raise FunctionClauseError" do
      assert_raise FunctionClauseError, fn -> Expression.eval(:not_binary, %{}) end
      assert_raise FunctionClauseError, fn -> Expression.eval("true", []) end
    end
  end

  describe "no arbitrary code — the language has no escape hatch" do
    test "function-call syntax does not evaluate; it is just unparseable text" do
      assert {:error, _} = Expression.eval("System.halt(1)", %{})
      assert {:error, _} = Expression.eval(~S|File.read!("/etc/passwd")|, %{})
    end
  end
end
