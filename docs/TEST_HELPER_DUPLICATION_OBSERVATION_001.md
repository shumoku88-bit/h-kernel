# Test helper duplication observation 001

ステータス: OBSERVATION ONLY  
更新日: 2026-08-11

## 問い

`tests/` の定型コードを共通化すると、h-kernel の教材としての局所可読性を落とさずに、どの程度の実質的な引き算ができるか。

大きなLOC削減値を先に目標にせず、まずdomain fixtureとは独立した中立helperだけを測る。

## 観察対象

PR #177 head `b5a28f40675d9dccafbadeb63f7994bb514a3252` を基準に、`tests/*.hs` 51 filesを観察した。

対象helper:

- `assertEqual`
- `mustRight`
- `assertRight`
- `assertLeftContaining`
- `exactlyOne`
- `failWith`
- `mustJust`

一時的なbranch-only GitHub Actionsで、各helperについて型signatureとそのhelper自身のequation/bodyだけを抽出し、完全一致bodyをbyte比較した。同名で意味やdiagnosticが異なるhelperは同一視していない。

観察run #2: `31457810630`  
結果: SUCCESS

## 結果

51 test filesのうち、対象7 helperの定義として495行を観察した。

完全一致bodyを理想的に一箇所へ集約した場合の削減上限は **366行** だった。

この366行には次の導入コストをまだ含めていない。

- shared test module自身
- 各testからのimport
- Cabal `other-modules` またはtest component共有設定
- variant差を保持するためのlocal helper

したがって366行は実削減値ではなく、現在の中立helper集合に対する上限である。

### 主な完全一致群

`assertEqual`:

- 38 occurrences
- 6 variants
- 最大variantは24 filesで完全一致
- 8 lines each
- 理論上の重複削減184 lines

`mustRight`:

- 39 occurrences
- 8 variants
- 最大variantは29 filesで完全一致
- 3 lines each
- 理論上の重複削減84 lines

`assertRight`:

- 6 occurrences
- 4 variants
- 最大variantは3 files
- 理論上の重複削減14 lines

`exactlyOne`:

- 5 occurrences
- 1 variant
- 理論上の重複削減12 lines

`mustJust`:

- 7 occurrences
- 5 variants
- 最大variantは3 files
- 理論上の重複削減6 lines

`assertLeftContaining` と `failWith` は今回の基準branchではそれぞれ1 definitionで、共通化対象ではなかった。

## 解釈

### 1. 中立helperは重複している

特に`assertEqual`と`mustRight`には明確なmechanical duplicationがある。これらはdomain vocabularyではなく試験器具なので、将来小さな`Test.Support` ownerを持つこと自体は不自然ではない。

### 2. しかし大規模削減の根拠にはならない

今回観察した中立helperを完全に共通化しても、導入コスト前の上限は366行である。

したがって、数千行規模のtest削減を得るには、Account / Journal / Plan / Budget / Editorなどのdomain fixtureやscenario setupまで共有化する必要がある。その共有化は別の意味論的判断であり、定型helper重複の数字から正当化できない。

### 3. Domain fixtureの局所性には教材価値がある

各Specの近くに、そのcontractを説明する最小source、Account、Plan、Transaction等が置かれていることには、test単体を読める価値がある。

fixtureが似ているという理由だけで中央fixture libraryへ移すと、LOCは減っても「このtestが何を前提にしているか」を別fileへ追う必要が生じる。

## 決定

**Repository-wideなtest framework化やdomain fixture共通化は行わない。**

現時点では、数千行の削減見積りをarchitecture目標として採用しない。

中立helperについては、次の条件を満たす場合にのみ将来の有限sliceとして再検討する。

1. exact同一bodyだけを共有する
2. domain fixtureやscenario meaningを共有moduleへ移さない
3. Cabal/importの追加コストを含む最終diffで十分な引き算になる
4. testを単独で読むときの意味が薄くならない
5. helper APIをtest frameworkへ成長させない

## 負の証拠の価値

今回の観察は「共通化できない」という意味ではない。

むしろ、h-kernelのtest code量の大部分が単純なassert helper boilerplateではないことを示す。大きなtest suiteはdomain contract、fail-closed evidence、writer law、source fixtureを明示しているため大きい。

削減するなら、行数ではなくその意味が本当に二重所有されている箇所を別途観察する。
