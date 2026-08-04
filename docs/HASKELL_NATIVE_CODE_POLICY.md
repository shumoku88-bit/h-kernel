# Haskell ネイティブ コード ポリシー


ステータス: 承認済み
承認日: 2026-08-01
更新日: 2026-08-04
範囲: リポジトリ内のHaskell sourceとそのtest


## 目的


`h-kernel`は、Haskellで動く家計簿を作るだけのprojectではない。


実用品を作りながら、型、純粋関数、代数的データ型、pattern matching、関数合成、高階関数、抽象化、導出可能な値を保存しない設計など、Haskellの考え方をコードそのものから読める教材でもある。


したがって、このprojectでいう「読めるコード」は、外側の手続きや設計慣習をHaskellの構文へ表面的に移したコードではない。


> Haskellの意味が、Haskellの形で見えるコードを目指す。


一般的な擬似コードへ近づけることや、あらゆる言語の利用者へ同じ見え方を提供することは目的ではない。Haskellを読むことで、Haskellの考え方が身につくことを重視する。


作者が読めなくなるコードは、testが通り性能が十分でも完成とは扱わない。ただし、まだ学んでいないHaskellの概念が登場すること自体は、読めないコードとは扱わない。新しい概念を学び、説明できるようになることも、このprojectの目的である。


## 決断


Domain calculationは、状態を順番に変更するprocedureとしてではなく、validな値から別のvalidな値への純粋な変換として表現する。


```text
validated input
  -> named domain transformation
  -> smaller valid intermediate values
  -> typed result
```


コードの中心は、「何を順番に実行するか」ではなく、次を示す。


- どの型からどの型へ変換するか

- どの状態が表現不可能か

- どのcaseがdomainに実在するか

- どの値が保存され、どの値が導出されるか

- 小さな純粋関数がどう合成されるか

- どのHaskellの抽象がdomain構造に対応しているか


## DomainとHaskellの二重譜読み


coding assistantは、対象sliceの唯一の作曲者ではない。domainの正規owner、作者との設計合意、現在の型、既存のtestとlawを譜面として読み、その意味をHaskellの形で演奏する。


実装前に、domainの譜面とHaskellの譜面を分けて読む。


### Domainの譜面


最初に、特定のHaskell機能を選ばず、対象domainを観察する。


- 今回の変換または法則を一文でどう表せるか

- 何が事実、policy、導出値、presentationか

- どの状態が不可能であるべきか

- 入力と出力のgrainは何か

- identity、順序、時間、provenanceは意味を持つか

- 失敗は独立に蓄積できるか、前の結果へ依存するか

- 値に自然な結合、単位元、順序、lawが存在するか


### Haskellの譜面


次に、観察した構造を最もよく見せるHaskellの書法を選ぶ。


- 型署名、newtype、opaque constructor、smart constructor

- ADTとpattern matching

- FunctorとTraversableによる形を保つ変換

- Applicativeによる独立した検証、Monadによる順序依存の変換

- Semigroup、Monoid、Foldable、foldMapによるlawfulな集約

- phantom type、GADT、DataKinds、type familyなどによる型上の状態や座標

- named pure functionと関数合成によるdata flow

- 明示的なIOまたはeffect boundary


これは機能の対応表ではない。同じHaskell機能でもdomain上の意味が異なれば別のownerと説明が必要であり、別のdomainを同じ書法へ機械的に揃えない。


### 対応を記録する


Haskell codeを変更するsliceでは、実装前の設計合意またはPR説明に、必要な範囲で次を短く記録する。


```text
Domain phrase:
Domain structure:
Haskell phrase:
Correspondence:
Rejected phrases:
Evidence:
```


- `Domain phrase`: 今回のdomain transformationまたはlaw

- `Domain structure`: 事実、policy、導出値、不変条件、失敗、grain、順序

- `Haskell phrase`: 採用する型、抽象、合成方法、effect boundary

- `Correspondence`: 何が型とdata flowから読めるようになり、どのinvalid state、branch、重複、手続き的stateを引けるか

- `Rejected phrases`: 検討したが対象domainには合わない書法と理由

- `Evidence`: example、focused test、property、law、既存contractなど、対応を観察する方法


小さな局所修正では簡潔にしてよい。ただし、新しい抽象、public API、domain owner、effect、順序依存を導入するときは省略しない。


AIは、使い慣れていること、まだrepositoryに存在しないこと、見栄えが新しいことを理由にHaskellの書法を選ばない。既存のADTと名前付き関数がdomainを最も正確に表すなら、それが採用する音である。高度な機能がdomain構造を正確に表すなら、初見であることだけを理由に退けない。


実装中に新しいidentity、順序、失敗、effect、source ownershipが必要だと分かった場合は、選んだ書法へ押し込まず、[`REPOSITORY_POLICY.md`](REPOSITORY_POLICY.md)の設計合意へ戻る。


## 肯定形


### 1. 型署名はドメインのストーリーを明らかにします


重要な関数は、実装を読まなくても入力、出力、失敗可能性が分かるsignatureを持つ。


```haskell
prepareReportBasis :: DateRange -> Journal -> ReportBasis
profitAndLoss      :: ReportBasis -> ProfitAndLoss
```


`Text -> Text`、巨大tuple、意味のない`Map Text Text`へdomainを押し込まない。意味が異なる値には異なる型またはconstructorを与える。


### 2. 代数データ型には実際の代替手段が存在する


domain上のcaseはADTで表し、pattern matchingで消費する。


- command種類

- アカウントの種類

- ロード/解析/検証エラー

- 結果報告

- 外部ポリシーの検証


複数の`Bool` flag、magic string、nullable fieldの組合せでcaseを表さない。


### 3. 純粋な変換がデフォルトです


会計計算、分類、集計、Report projection、rendering primitiveは純粋関数を基本とする。


IOはfile読込み、現在日付、環境変数、標準出力など、外界との境界に限定する。


`IO`の中でdomain calculationを手続き的に進めるのではなく、IO shellがvalidな値をpure coreへ渡す。


### 4. 合成を通じてデータの流れが見える


複数の変換は、深いcontrol-flow nestではなく、一方向のdata flowとして読める形を優先する。


```haskell
reportBook =
  publishReports
    . projectReports
    . prepareReportBasis
```


point-free styleでも引数を明示した形でもよい。どちらを選ぶかは、変換の向きとdomainの関係がよりよく見える方で決める。


### 5. 中間名はドメイン名です


`x`、`tmp`、`result2`ではなく、`periodBalances`、`unclassifiedAccounts`、`currentEarnings`のように、値が会計上何であるかを名前にする。


`let`と`where`は、procedureの細かいstep番号を増やすためではなく、式を意味のあるdomain partsへ分けるために使う。


### 6. 繰り返しは意味論的な結合子になる


同じ変換が複数Reportへ現れた場合、syntax上のhelperではなく、共有している会計概念を所有する関数へする。


例:


- `balancesInPeriod`

- `classifyFlow`

- `aggregateByDay`

- `projectAccountLines`


局所再帰や`go`関数が自然な場合は使ってよい。ただし、その再帰が何を生成するか分かるdomain ownerを外側に置く。


### 7. 導出された値は導出されたままになる


Net、Delta、Remaining、Balanced statusなど、元のtyped coordinatesから一意に求まる値は、矛盾し得る重複stateとして保持しない。


Haskellの関数として導出し、invalid combinationをconstructorで作れないようにする。


### 8. コレクション処理では、Haskell の抽象化を意図的に使用します。


配列・list・Mapの処理は、意味に応じて`map`、`filter`、`foldMap`、`foldl'`、`traverse`、`Map` combinator、`NonEmpty`、`Semigroup`、`Monoid`、`Functor`、`Applicative`などを使う。


これらを一般的なloopへ戻して読みやすくしたことにはしない。抽象が何をまとめ、何を保証し、どの手続き的状態を消したかを読めるようにする。


## Advanced Haskell は学習目標の一部です


高度なHaskellの機能は、避ける対象ではなく学習対象である。


たとえば、次の機能がdomain構造をより正確に表すなら採用を検討する。


- ファントムタイプ

- GADT

- データの種類

- タイプファミリー

・上位タイプ

- 型クラス

- 戦略を導き出す

- 光学系

- 再帰スキーム

- 効果の抽象化

- カテゴリ理論の抽象化


この一覧は導入checklistではない。しかし「初見では難しい」「普通のADTだけでも書ける」という理由だけで退けない。


各PRが新しい高度機能を導入することも求めない。既存の型と標準的な抽象だけでdomainが明瞭になるsliceは、それ自体でHaskell-nativeである。新規性ではなく、domainとの対応と、何を引けたかで判断する。


高度な機能を使う変更は、次を示す。


1. どのdomain構造に対応しているか

2. どのinvalid state、branch、重複、変換を減らすか

3. 型signatureから何が新しく読めるようになるか

4. testまたはexampleで使い方をどう観察できるか

5. 作者がその仕組みを学び、自分の言葉で説明できるか


必要なら、module comment、短いdesign note、focused example、property testを教材として残す。


難しさを隠すためにHaskellの機能を使わないのではなく、難しさの所在を型と抽象へ正しく移し、学べる形で表す。


## 避けるべきパターン


### 深い手続き型ネスト


次のような構造が重なる場合、関数境界またはdomain typeの不足を疑う。


```text
case
  -> if
       -> let
            -> case
                 -> fold with record updates
```


一つの`case`や`if`を禁止するものではない。読み手が複数の局所状態と分岐条件を頭の中で保持し続けないと意味が分からない構造を避ける。


### 命令型状態に関する Haskell 構文


次の形を増やさない。


- accumulator recordを何段階も更新してprocedureを模倣する

- mutable variableの代わりに同じ名前のprimed valueを長く連鎖させる

- Reportごとにrowをappendしながら結果を組み立てる

- `do` blockへdomain calculationを埋め込む

- generic dictionaryへfieldを足し引きしてdomain objectを模倣する


foldが自然な集計にはfoldを使う。ただしfold内部が多数のbranchとrecord mutationの写像になった場合は、入力factの分類、出力monoid、Applicativeな独立集計など、Haskellとして自然な分解を先に検討する。


### 外側の設計慣習を表面的に移植すること


次を理由なく持ち込まない。


- 既成のlayer名と責務配置を、その意味を確かめずmoduleへ写す

- method call chainを関数呼出しへ置き換えただけの構造

- exceptionとfallbackを前提にしたnormal path

- nullable objectを後から何度も検査する流れ

- untyped dictionaryを中心にしたdata passing

- commandごとに似たprocedureを複製する構造


必要な責務分離は、Haskellのmodule、型、純粋関数、opaque constructor、明示的なeffect boundaryで表現する。


### 不透明な賢さ


高度なHaskellと、意味を隠す技巧は区別する。


次の状態はreviewで立ち止まる。


- 抽象のdomain対応を誰も説明できない

- 型errorを避けるためだけのwrapper変換が増える

- operator chainを展開しないとdata flowが分からない

- custom type classのlawやinstance選択が不明瞭

- effect abstractionが実際のeffect境界を曖昧にする

- category-theoreticな構造名が実装上の対応を持たない


問題は機能の高度さではなく、何を表したかが失われていることである。


## ネストルール


数値による一律のnesting limitは設けない。ただし、次のいずれかが起きたコードはreviewで立ち止まる。


- domain functionの主要経路に3段以上の意味的な分岐が重なる

- 一つの関数で複数のindependent stateを追跡する

- branchを抜けた後も、それ以前のcaseを覚えていないと値の意味が分からない

- `where`の局所関数が別の局所関数の内部状態へ依存する

- 型よりコメントがinvalid stateを説明している

- 一つの関数がparse、validate、classify、aggregate、renderの複数段階を所有する


この場合の第一候補は、comment追加や一般的なprocedureへの書き換えではなく、次のいずれかである。


- domain ADTを導入する

- smart constructorへvalidationを移す

- pure transformationを名前付き関数へ切り出す

- shared semantic ownerへ集計を移す

- data grainを分ける

- 導出可能なstateを削る

- 適切なFunctor、Applicative、Foldable、Traversable、Monoidなどの構造を見つける


これは自動lintのhard limitではない。reviewで立ち止まるための煙探知器である。


## 著者が判読できる受諾


主要なdomain codeは、作者が次を説明できなければならない。


1. 入力の型と意味

2. 出力の型と意味

3. 途中で失敗し得る場所

4. 保存している事実と導出している値の区別

5. どの関数がどのdomain conceptを所有するか

6. 型から実装を追ったときの変換方向

7. 使用したHaskellの抽象が何を表しているか

8. Domain phraseとHaskell phraseがどう対応し、なぜ他の書法を採用しなかったか


説明に「このflagが立っている場合だけ、この前のbranchで更新されたstateを見て」のような局所実行履歴が頻出する場合、構造を見直す。


作者がまだ知らない概念を使った場合は、概念を削除するのではなく、学習して説明可能にする。AIが生成できたこと、testが通ったこと、速度が改善したことだけを理由にmergeしない。


## 質問を確認する


Haskell codeのPRでは、少なくとも次を確認する。


1. signatureからdomain transformationを説明できるか

2. invalid stateは型で減っているか、それともbranchで処理しているか

3. control flowよりdata flowが前面に出ているか

4. 深いnestはdomain caseを表すADTや抽象へ置き換えられないか

5. accumulator更新は本当に自然なfoldか、procedureの翻訳か

6. intermediate valueは会計上の名前を持つか

7. 同じ意味が複数関数で再実装されていないか

8. IOとpure calculationの境界は見えるか

9. 使用したHaskellの機能は、どのdomain構造を表し、何を削ったか

10. このコードを読むことで、使われているHaskellの考え方を追えるか

11. 実装前に読んだDomain phraseとHaskell phraseは、実際の型、data flow、testに一致しているか

12. 別のdomainで使った書法を、その意味を確かめず機械的に繰り返していないか


最後の問いは装飾ではなくacceptance criterionである。ただし、毎PRで新しい概念を追加するnovelty quotaではない。既存の型・関数・抽象の関係が教材として読めることを求める。


## レポートパイプラインとの関係


[`REPORT_PIPELINE_POLICY.md`](REPORT_PIPELINE_POLICY.md)の共有Report Basisは、性能だけを目的にしない。


Reportごとのprocedureを一つにまとめるのではなく、canonical factsをtyped transformationと適切なHaskellの抽象で共有し、各Reportをpure projectionとして読める構造にする。


したがって、共有basis実装は次を同時に満たす。


- repeated scanを減らす

- semantic ownerを一つにする

- deep nestingを増やさない

- Report projectionを小さくする

- Haskellの型、合成、抽象として読める


## 美しい引き算


このprojectでいう「美しい引き算」は、Haskellの表現力を引くことではない。


- impossible stateを引く

- duplicated calculation pathを引く

- defensive branchを引く

- mutable-style intermediate stateを引く

- rendererやIOからdomain calculationを引く

- 外側のarchitectureをHaskellへ翻訳しただけの層を引く


引いたあとに残る、型、関数、抽象の関係がHaskellとして読めることを目標とする。
