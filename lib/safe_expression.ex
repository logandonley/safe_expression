defmodule SafeExpression do
  @moduledoc """
  A constrained, safe expression language for comparisons, boolean logic, and
  dotted field access over caller-supplied bindings — with no arbitrary code.

  Deliberately **not** `Code.eval_*`/`string_to_quoted`: a hand-written
  tokenizer → recursive-descent parser → tree-walking evaluator, so the only
  things that can ever happen are field lookups, comparisons, and boolean logic —
  there is no path to call a function, spawn, or touch the world.

  `eval/2` is total over valid argument types: a malformed expression, an unknown
  operator, or a type mismatch (ordering non-numbers, boolean logic on a
  non-boolean) returns `{:error, reason}` rather than raising. The grammar, by
  precedence (loosest first):

      expr   := or
      or     := and  ("||" and)*
      and    := eq   ("&&" eq)*
      eq     := rel  (("==" | "!=") rel)*
      rel    := unary (("<" | ">" | "<=" | ">=") unary)*
      unary  := "!" unary | primary
      primary:= number | string | "true" | "false" | "null"
              | path | "(" expr ")"
      path   := ident ("." ident)*   # a dotted lookup into the bindings map

  Field access reads the string-keyed `bindings` map. A missing path resolves to
  `nil`, so `x == null` tests presence.

  Two deliberate limits, since this is a predicate language and not arithmetic:
  number literals are non-negative (a negative value reaches an expression
  through its bindings, never as a literal), and a string literal is taken
  verbatim — a backslash escapes the next character (so `"\""` is a quote) but
  there are no `\n`-style sequences, since expressions compare against
  already-decoded values.
  """

  @type value :: number() | binary() | boolean() | nil | map() | list()

  @doc """
  Evaluates `source` against the `bindings` map. Returns `{:ok, value}` with the
  result's native type, or `{:error, reason}` for a malformed expression or a
  type mismatch.
  """
  @spec eval(String.t(), map()) :: {:ok, value()} | {:error, term()}
  def eval(source, bindings) when is_binary(source) and is_map(bindings) do
    with {:ok, tokens} <- tokenize(source),
         {:ok, ast} <- parse(tokens) do
      evaluate(ast, bindings)
    end
  end

  ## Tokenizer

  # Two-character operators are matched before their single-character prefixes.
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
      true -> {:error, {:unexpected_char, <<c::utf8>>}}
    end
  end

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

  defp scan_number(source, acc) do
    {digits, rest} = take_while(source, &number_char?/1)

    case parse_number(digits) do
      {:ok, n} -> scan(rest, [{:number, n} | acc])
      :error -> {:error, {:bad_number, digits}}
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

  defp drop(source, 0), do: source
  defp drop(<<_::utf8, rest::binary>>, n), do: drop(rest, n - 1)

  ## Parser — recursive descent, loosest precedence first.

  defp parse(tokens) do
    case parse_or(tokens) do
      {:ok, ast, []} -> {:ok, ast}
      {:ok, _ast, leftover} -> {:error, {:unexpected_tokens, leftover}}
      {:error, _} = err -> err
    end
  end

  defp parse_or(tokens), do: parse_binary(tokens, [:or], &parse_and/1)
  defp parse_and(tokens), do: parse_binary(tokens, [:and], &parse_eq/1)
  defp parse_eq(tokens), do: parse_binary(tokens, [:eq, :neq], &parse_rel/1)
  defp parse_rel(tokens), do: parse_binary(tokens, [:lt, :gt, :lte, :gte], &parse_unary/1)

  # Left-associative chains of same-precedence operators.
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
        _ -> {:error, :missing_close_paren}
      end
    end
  end

  defp parse_primary([]), do: {:error, :unexpected_end}
  defp parse_primary([token | _]), do: {:error, {:unexpected_token, token}}

  defp parse_path(segments, [{:dot}, {:ident, name} | rest]),
    do: parse_path([name | segments], rest)

  defp parse_path(_segments, [{:dot} | _]), do: {:error, :trailing_dot}
  defp parse_path(segments, rest), do: {:ok, {:path, Enum.reverse(segments)}, rest}

  ## Evaluator — a tree walk; the only effects are reads from `bindings`.

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
