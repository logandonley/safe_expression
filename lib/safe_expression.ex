defmodule SafeExpression do
  @moduledoc """
  `SafeExpression` evaluates a small expression language against values in an
  Elixir map. Use it for configurable rules, filters, and routing decisions that
  need comparisons and boolean logic but must not execute Elixir code.

  The module uses a hand-written tokenizer, recursive-descent parser, and
  tree-walking evaluator. Expressions cannot call functions, spawn processes, or
  otherwise perform effects.

  The grammar, from lowest to highest precedence, is:

      expr    := or
      or      := and ("||" and)*
      and     := eq ("&&" eq)*
      eq      := rel (("==" | "!=") rel)*
      rel     := unary (("<" | ">" | "<=" | ">=") unary)*
      unary   := "!" unary | primary
      primary := number | string | "true" | "false" | "null" | "nil"
               | path | "(" expr ")"
      path    := ident ("." ident)*

  Paths read string keys only. Bindings can contain any Elixir term. A bare path
  returns that term unchanged. A missing segment, a non-map intermediate value,
  and an explicitly stored `nil` all resolve to `nil`. The language does not
  distinguish among these cases. `nil` is an alias for the `null` literal.

  Equality uses Elixir's `==` and `!=` semantics, including equality between
  numerically equivalent integers and floats. Ordering accepts numbers only.
  `!`, `&&`, and `||` accept booleans only. The evaluator does not coerce values.

  Number literals are non-negative. A backslash in a string literal escapes the
  next character verbatim; sequences such as `\\n` do not produce a newline.

  Expressions cannot execute arbitrary code. Evaluation does not limit CPU time
  or memory use. Applications that accept untrusted expressions should limit the
  length of `source` before they call `eval/2`.
  """

  @type value :: term()
  @type ordering_operator :: :lt | :gt | :lte | :gte
  @type reason ::
          :invalid_utf8
          | :unterminated_string
          | :unexpected_end
          | :missing_closing_parenthesis
          | :trailing_dot
          | :unexpected_token
          | {:unexpected_character, binary()}
          | {:invalid_number, binary()}
          | {:not_boolean, term()}
          | {:not_comparable, ordering_operator(), term(), term()}

  @doc """
  Evaluates `source` against `bindings`. Paths read string keys only.

  Returns `{:ok, value}` with the result's native type, or `{:error, reason}` for
  malformed input or an operator type mismatch.

  ## Examples

      iex> SafeExpression.eval(~s(count >= 2 && kind == "webhook"), %{
      ...>   "count" => 3,
      ...>   "kind" => "webhook"
      ...> })
      {:ok, true}

      iex> SafeExpression.eval("payload", %{"payload" => {:queued, 42}})
      {:ok, {:queued, 42}}

      iex> SafeExpression.eval("value", %{value: 42})
      {:ok, nil}
  """
  @spec eval(String.t(), map()) :: {:ok, value()} | {:error, reason()}
  def eval(source, bindings) when is_binary(source) and is_map(bindings) do
    with {:ok, tokens} <- tokenize(source),
         {:ok, ast} <- parse(tokens) do
      evaluate(ast, bindings)
    end
  end

  ## Tokenizer

  # The scanner matches two-character operators before their single-character prefixes.
  @two_char %{"==" => :eq, "!=" => :neq, "<=" => :lte, ">=" => :gte, "&&" => :and, "||" => :or}
  @one_char %{
    "<" => :lt,
    ">" => :gt,
    "!" => :not,
    "(" => :lparen,
    ")" => :rparen,
    "." => :dot
  }

  defp tokenize(source), do: scan(source, [])

  defp scan("", acc), do: {:ok, Enum.reverse(acc)}

  defp scan(<<c::utf8, rest::binary>> = source, acc) do
    cond do
      ws?(c) -> scan(rest, acc)
      two = match_two(source) -> scan(drop(source, 2), [two | acc])
      one = Map.get(@one_char, <<c::utf8>>) -> scan(rest, [{one} | acc])
      quote?(c) -> scan_string(source, acc)
      digit?(c) -> scan_number(source, acc)
      ident_start?(c) -> scan_ident(source, acc)
      true -> {:error, {:unexpected_character, <<c::utf8>>}}
    end
  end

  defp scan(<<_::binary>>, _acc), do: {:error, :invalid_utf8}

  defp match_two(<<a::utf8, b::utf8, _::binary>>) do
    case Map.fetch(@two_char, <<a::utf8, b::utf8>>) do
      {:ok, tag} -> {tag}
      :error -> nil
    end
  end

  defp match_two(_), do: nil

  defp scan_string(<<q::utf8, rest::binary>>, acc), do: scan_string(rest, <<q::utf8>>, "", acc)

  defp scan_string("", _q, _buf, _acc), do: {:error, :unterminated_string}

  defp scan_string(<<q::utf8, rest::binary>>, <<q::utf8>>, buf, acc),
    do: scan(rest, [{:string, buf} | acc])

  defp scan_string(<<"\\", c::utf8, rest::binary>>, q, buf, acc),
    do: scan_string(rest, q, buf <> <<c::utf8>>, acc)

  defp scan_string(<<c::utf8, rest::binary>>, q, buf, acc),
    do: scan_string(rest, q, buf <> <<c::utf8>>, acc)

  defp scan_string(<<_::binary>>, _q, _buf, _acc), do: {:error, :invalid_utf8}

  defp scan_number(source, acc) do
    {digits, rest} = take_while(source, &number_char?/1)

    case parse_number(digits) do
      {:ok, n} -> scan(rest, [{:number, n} | acc])
      :error -> {:error, {:invalid_number, digits}}
    end
  end

  defp scan_ident(source, acc) do
    {word, rest} = take_while(source, &ident_char?/1)
    scan(rest, [keyword(word) | acc])
  end

  defp keyword("true"), do: {:bool, true}
  defp keyword("false"), do: {:bool, false}
  defp keyword("null"), do: {:null}
  defp keyword("nil"), do: {:null}
  defp keyword(word), do: {:ident, word}

  defp parse_number(digits) do
    parser = if String.contains?(digits, "."), do: &Float.parse/1, else: &Integer.parse/1

    case parser.(digits) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp ws?(c), do: c in [?\s, ?\t, ?\n, ?\r]
  defp quote?(c), do: c in [?", ?']
  defp digit?(c), do: c in ?0..?9
  defp number_char?(c), do: digit?(c) or c == ?.
  defp ident_start?(c), do: c in ?a..?z or c in ?A..?Z or c == ?_
  defp ident_char?(c), do: ident_start?(c) or digit?(c)

  defp take_while(source, pred), do: take_while(source, pred, "")

  defp take_while(<<c::utf8, rest::binary>> = source, pred, buf) do
    if pred.(c), do: take_while(rest, pred, buf <> <<c::utf8>>), else: {buf, source}
  end

  defp take_while("", _pred, buf), do: {buf, ""}

  defp take_while(source, _pred, buf), do: {buf, source}

  defp drop(source, 0), do: source
  defp drop(<<_::utf8, rest::binary>>, n), do: drop(rest, n - 1)

  ## Parser

  defp parse(tokens) do
    case parse_or(tokens) do
      {:ok, ast, []} -> {:ok, ast}
      {:ok, _ast, _leftover} -> {:error, :unexpected_token}
      {:error, _} = err -> err
    end
  end

  defp parse_or(tokens), do: parse_binary(tokens, [:or], &parse_and/1)
  defp parse_and(tokens), do: parse_binary(tokens, [:and], &parse_eq/1)
  defp parse_eq(tokens), do: parse_binary(tokens, [:eq, :neq], &parse_rel/1)
  defp parse_rel(tokens), do: parse_binary(tokens, [:lt, :gt, :lte, :gte], &parse_unary/1)

  # Binary operators with the same precedence associate to the left.
  defp parse_binary(tokens, ops, next) do
    with {:ok, left, rest} <- next.(tokens) do
      fold_binary(left, rest, ops, next)
    end
  end

  defp fold_binary(left, [{op} | rest], ops, next)
       when op in [:or, :and, :eq, :neq, :lt, :gt, :lte, :gte] do
    if op in ops do
      with {:ok, right, rest} <- next.(rest) do
        fold_binary({:binary, op, left, right}, rest, ops, next)
      end
    else
      {:ok, left, [{op} | rest]}
    end
  end

  defp fold_binary(left, rest, _ops, _next), do: {:ok, left, rest}

  defp parse_unary([{:not} | rest]) do
    with {:ok, operand, rest} <- parse_unary(rest) do
      {:ok, {:not, operand}, rest}
    end
  end

  defp parse_unary(tokens), do: parse_primary(tokens)

  defp parse_primary([{:number, n} | rest]), do: {:ok, {:lit, n}, rest}
  defp parse_primary([{:string, s} | rest]), do: {:ok, {:lit, s}, rest}
  defp parse_primary([{:bool, b} | rest]), do: {:ok, {:lit, b}, rest}
  defp parse_primary([{:null} | rest]), do: {:ok, {:lit, nil}, rest}

  defp parse_primary([{:ident, name} | rest]), do: parse_path([name], rest)

  defp parse_primary([{:lparen} | rest]) do
    with {:ok, inner, rest} <- parse_or(rest) do
      case rest do
        [{:rparen} | rest] -> {:ok, inner, rest}
        _ -> {:error, :missing_closing_parenthesis}
      end
    end
  end

  defp parse_primary([]), do: {:error, :unexpected_end}
  defp parse_primary([_token | _]), do: {:error, :unexpected_token}

  defp parse_path(segments, [{:dot}, {:ident, name} | rest]),
    do: parse_path([name | segments], rest)

  defp parse_path(_segments, [{:dot} | _]), do: {:error, :trailing_dot}
  defp parse_path(segments, rest), do: {:ok, {:path, Enum.reverse(segments)}, rest}

  ## Evaluator

  defp evaluate({:lit, value}, _bindings), do: {:ok, value}

  defp evaluate({:path, segments}, bindings), do: {:ok, lookup(segments, bindings)}

  defp evaluate({:not, operand}, bindings) do
    with {:ok, value} <- evaluate(operand, bindings), {:ok, b} <- as_boolean(value) do
      {:ok, not b}
    end
  end

  defp evaluate({:binary, :and, left, right}, bindings) do
    with {:ok, l} <- eval_boolean(left, bindings) do
      if l, do: eval_boolean(right, bindings) |> wrap(), else: {:ok, false}
    end
  end

  defp evaluate({:binary, :or, left, right}, bindings) do
    with {:ok, l} <- eval_boolean(left, bindings) do
      if l, do: {:ok, true}, else: eval_boolean(right, bindings) |> wrap()
    end
  end

  defp evaluate({:binary, op, left, right}, bindings) do
    with {:ok, l} <- evaluate(left, bindings), {:ok, r} <- evaluate(right, bindings) do
      compare(op, l, r)
    end
  end

  defp eval_boolean(node, bindings) do
    with {:ok, value} <- evaluate(node, bindings), do: as_boolean(value)
  end

  defp wrap({:ok, b}), do: {:ok, b}
  defp wrap({:error, _} = err), do: err

  defp compare(:eq, l, r), do: {:ok, l == r}
  defp compare(:neq, l, r), do: {:ok, l != r}

  defp compare(op, l, r) when op in [:lt, :gt, :lte, :gte] do
    if is_number(l) and is_number(r) do
      {:ok, ordered(op, l, r)}
    else
      {:error, {:not_comparable, op, l, r}}
    end
  end

  defp ordered(:lt, l, r), do: l < r
  defp ordered(:gt, l, r), do: l > r
  defp ordered(:lte, l, r), do: l <= r
  defp ordered(:gte, l, r), do: l >= r

  defp as_boolean(b) when is_boolean(b), do: {:ok, b}
  defp as_boolean(other), do: {:error, {:not_boolean, other}}

  defp lookup(segments, bindings) do
    Enum.reduce(segments, bindings, fn
      key, acc when is_map(acc) -> Map.get(acc, key)
      _key, _acc -> nil
    end)
  end
end
