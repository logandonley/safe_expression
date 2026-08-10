# SafeExpression

`SafeExpression` evaluates a small expression language against values in an Elixir map. Use it for configurable rules, filters, and routing decisions that need comparisons and boolean logic but must not execute Elixir code.

The language supports literals, comparisons, boolean logic, and string-keyed path lookup. The library has no runtime dependencies.

`SafeExpression` uses a hand-written tokenizer, parser, and evaluator instead of `Code.eval_*`. Expressions cannot call functions, spawn processes, or perform I/O.

Evaluation does not limit CPU time or memory use. Applications that accept untrusted expressions should limit the length of `source` before they call `SafeExpression.eval/2`.

## Installation

Add the Hex package to `mix.exs`:

```elixir
{:safe_expression, "~> 0.1.0"}
```

To use the tagged source directly, add the Git dependency:

```elixir
{:safe_expression,
 git: "https://github.com/logandonley/safe_expression.git",
 tag: "v0.1.0"}
```

## Usage

```elixir
bindings = %{
  "count" => 10,
  "kind" => "webhook",
  "user" => %{"active" => true}
}

SafeExpression.eval(~s(count >= 5 && kind == "webhook"), bindings)
#=> {:ok, true}

SafeExpression.eval("user.active", bindings)
#=> {:ok, true}

SafeExpression.eval("payload", %{"payload" => {:queued, 42}})
#=> {:ok, {:queued, 42}}
```

`eval/2` returns an Elixir value, which is not necessarily a boolean. A bare path can return any term supplied by the caller. A literal returns its corresponding Elixir value.

## Language

The grammar is listed from lowest to highest precedence:

```text
expr    := or
or      := and ("||" and)*
and     := eq ("&&" eq)*
eq      := rel (("==" | "!=") rel)*
rel     := unary (("<" | ">" | "<=" | ">=") unary)*
unary   := "!" unary | primary
primary := number | string | "true" | "false" | "null" | "nil"
         | path | "(" expr ")"
path    := ident ("." ident)*
```

Operators at the same precedence are left-associative. Parentheses override precedence.

Identifiers begin with an ASCII letter or underscore and continue with ASCII letters, digits, or underscores. Spaces, tabs, newlines, and carriage returns are whitespace.

Number literals are non-negative integers or floats. Negative numbers can still be compared when they come from bindings. String literals can use single or double quotes. A backslash escapes the next character verbatim. For example, `"a\nb"` evaluates to `"anb"`, not to a string that contains a newline.

`nil` is an alias for the `null` literal.

## Bindings and value semantics

Paths read string keys only:

```elixir
SafeExpression.eval("user.name", %{"user" => %{"name" => "Ada"}})
#=> {:ok, "Ada"}

SafeExpression.eval("value", %{value: 42})
#=> {:ok, nil}
```

A missing segment, a non-map intermediate value, and an explicitly stored `nil` all resolve to `nil`. The language cannot distinguish those cases.

Bindings may contain any Elixir term:

- `==` and `!=` use Elixir equality semantics. Numerically equivalent integers and floats compare equal; other values are not coerced.
- `<`, `>`, `<=`, and `>=` accept numbers only.
- `!`, `&&`, and `||` accept booleans only.
- `&&` and `||` short-circuit.

## Errors

When `source` is a binary and `bindings` is a map, malformed expressions and operator type mismatches return `{:error, reason}`. The complete reason contract is:

```elixir
:invalid_utf8
:unterminated_string
:unexpected_end
:missing_closing_parenthesis
:trailing_dot
:unexpected_token
{:unexpected_character, character}
{:invalid_number, source}
{:not_boolean, value}
{:not_comparable, operator, left, right}
```

`character` and the `source` value in `{:invalid_number, source}` are binaries. `operator` is one of `:lt`, `:gt`, `:lte`, or `:gte`. `eval/2` raises `FunctionClauseError` when `source` is not a binary or `bindings` is not a map.

## License

SafeExpression uses the [MIT License](https://github.com/logandonley/safe_expression/blob/main/LICENSE).
