# .credo.exs
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: []
      },
      checks: [
        {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 10]},
        {Credo.Check.Refactor.NestingDepth, [max_nesting: 3]},
        {Credo.Check.Refactor.CondStatements, []}
      ]
    }
  ]
}
