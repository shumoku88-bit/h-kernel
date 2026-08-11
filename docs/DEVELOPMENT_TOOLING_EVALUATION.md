# Development Tooling Evaluation Ledger

ステータス: active observation ledger  
範囲: build/test/analysis/performance/AI-context tooling

## Purpose

開発toolは、h-kernelのcorrectness、feedback speed、diagnosis、maintenance cost、AI context efficiencyを実際に改善する場合だけ採用する。

新しいtoolやframeworkを増やすこと自体を目的にしない。toolのsuggestionをdomain meaningより優先しない。

## Adoption rule

```text
Candidate
  -> observation
  -> repeated evidence
  -> Adopt / Keep observing / Reject
```

mandatory CI gateにする前に、signal、false positive、setup/CI cost、version constraints、failure modeを確認する。

## Measurement axes

### Quality

- real defect
- dead/redundant code
- unsafe/incomplete pattern
- reproducible architecture or source-shape problem
- false/noisy suggestion

### Operational cost

- dependency/config/file追加
- local cold/warm time
- CI time
- install/download cost
- compiler/version constraint
- maintenance burden

### AI context efficiency

`sqz`や`rtk`のようなtoolでは、raw/compressed output、recovery、retry、missed detail、wrong conclusionを測る。

最大圧縮率ではなく、**correct workに必要な情報を少ないcontextで保持できるか**を評価する。

source mutation、CI failure、compiler error、security-sensitive outputではexact evidenceを優先する。

### Resource use

repeated output、unnecessary execution、CI/build workを減らせるかを見る。token countからenergy/carbonを直接推定しない。

## Candidate inventory

| Tool | Intended value | Initial mode | Main risk |
|---|---|---|---|
| HLS | navigation/refactor feedback | local | setup complexity |
| HLint | suspicious/redundant idioms | observation | semantic/style noise |
| Weeder | dead-code audit | periodic | root/version accuracy |
| cabal-gild | deterministic Cabal formatting | observation | large churn |
| GHC `+RTS -s` / eventlog / heap profile | runtime diagnosis | targeted | measurement misuse |
| Criterion | repeatable microbenchmark | deferred | framework before question |
| hsec tools | dependency advisory observation | periodic | network/cache noise |
| `sqz` | AI output compression/dedup | experiment | hidden context |
| `rtk` | command-aware output filtering | experiment | hidden detail/interception |

## Tooling rules

- HLint/Weeder findings are evidence, not edit/delete authority.
- formatter adoption requires reviewing the resulting source shape and diff noise.
- performance tooling starts from a concrete runtime question.
- generic framework/dependencyは、実在するrecurring problemが示されるまで導入しない。
- tool outputがdomain vocabulary、identity、source ownership、exact arithmetic、writer safetyを変える理由にはならない。

## Experiment record

```text
Tool / version:
Environment:
Question:
Baseline:
Observed signal:
False/noisy signal:
Elapsed/setup/CI cost:
Token/output effect:
Retries/recoveries:
Decision:
Reason:
```

## Current direction

HLint、Weeder、cabal-gild、runtime observation、AI-context toolはそれぞれ独立に評価する。結果が有用でも、一回の観察だけでrepository lawやmandatory CIへ昇格させない。
