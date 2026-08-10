defmodule SafeExpression.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/logandonley/safe_expression"

  def project do
    [
      app: :safe_expression,
      version: @version,
      elixir: "~> 1.15",
      name: "SafeExpression",
      description:
        "An expression evaluator with no runtime dependencies for comparisons, boolean logic, " <>
          "and string-keyed field access in caller-provided Elixir maps.",
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: [
        main: "readme",
        extras: ["README.md"],
        source_ref: "v#{@version}"
      ],
      dialyzer: [
        plt_core_path: "priv/plts/core.plt",
        plt_file: {:no_warn, "priv/plts/project.plt"}
      ],
      deps: deps()
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.40.3", only: :dev, runtime: false},
      {:stream_data, "~> 1.4", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
