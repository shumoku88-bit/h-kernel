# プラットフォームに依存しないアプリケーション ポリシー


ステータス: 承認済み
承認日: 2026-08-02
範囲: 型付きエンジン、アプリケーション境界、および将来の配信アダプター


## 目的


`h-kernel`の将来の配布形態は、まだ決めない。


候補には次が含まれる。


- macOS アプリケーション

- Windowsアプリケーション

- Androidアプリ

- iPhone/iPadアプリ

- ブラウザアプリケーション

- ローカルファーストのアプリケーション

- クライアントサーバーアプリケーション

- コマンドラインアプリケーション


現在どれか一つへ最適化するのではなく、純粋な会計核を保つことで、後から複数のdelivery surfaceを選べる状態を維持する。


> すべてのplatformへ今から対応するのではなく、どのplatformにも会計核を所有させない。


## 決断


`h-kernel`の中心は、OS、画面toolkit、browser、network protocol、database、filesystem layoutを知らないHaskell libraryとする。


```text
external input
  -> delivery adapter
  -> application input
  -> validated domain value
  -> pure accounting transformation
  -> typed domain result
  -> delivery adapter
  -> external output
```


CLIは完成形ではなく、一つ目のdelivery adapterである。


将来のWeb server、desktop shell、mobile bridge、browser bridgeも、同じpure coreの外側に置く。


## 依存関係の方向


依存方向は外側から内側への一方向とする。


```text
macOS / Windows / Android / iOS / browser / CLI
                         |
                         v
              application boundary
                         |
                         v
        Journal / Ledger / Engine / Report
```


Domain moduleがplatform adapterをimportしてはならない。


特に、次のmodule群はplatform-specific dependencyを持たない。


- `HKernel.Account`

- `HKernel.Money`

- `HKernel.Ledger`

- `HKernel.Journal`

- `HKernel.Engine`

- `HKernel.Report`

- 純粋なポリシーおよび予測モジュール


## 安定したコア、交換可能なエッジ


### 純粋なドメインコア


Pure coreは次を所有する。


- Account、Commodity、Quantity、Amount、Posting、Transactionのinvariant

- Journal syntaxから得たpure document representation

- 仕訳帳の検証

- 正確な算術

- 会計上の事実と質問

- レポートモデル

- ドメインおよび検証エラー


Pure coreは次を所有しない。


- ウィンドウのライフサイクル

- 画面ナビゲーション

- HTTPルーティング

- JSONエンコーディング

- SQLiteスキーマ

- ブラウザストレージ

- Android コンテンツプロバイダー

- Apple プラットフォームの永続性

- Windows ファイルシステムの規則

- プロセス終了コード

- ANSI 端末スタイル


### アプリケーション境界


必要になった時点で、UIやtransportから独立したapplication inputとresultを追加する。


例えば、将来の形は次のようになり得る。


```haskell
runQuery
  :: ApplicationQuery
  -> Journal
  -> Either ApplicationError ApplicationResult
```


ただし、将来を想像して巨大な`ApplicationService`やgeneric repository frameworkを先に作らない。


実在する最初のnon-CLI use caseが現れたとき、そのuse caseに必要な最小のapplication boundaryを導入する。


### 配信アダプター


Delivery adapterは外界固有の責務を持つ。


例:


- CLI: 引数解析、環境変数、stdout、stderr、終了ステータス

- HTTP: ルーティング、認証、リクエスト/レスポンスのエンコーディング

- ブラウザ: JavaScript または WebAssembly ブリッジ、ブラウザ ストレージ

- デスクトップ: ウィンドウイベント、ファイルピッカー、OS統合

- モバイル: ライフサイクル、安全なストレージ、共有/インポート/エクスポート、プラットフォームブリッジ


各adapterはpure coreの型を利用するが、pure coreをadapter都合の型へ変形しない。


## 永続性は引き続き交換可能


現在の`HKernel.Loader`はfilesystem journal graphを読むadapterである。


これはJournalの唯一の保存方式とは扱わない。


将来の保存候補には次があり得る。


- 通常のジャーナルファイル

- アプリケーションサンドボックスファイル

- SQLite

- ブラウザストレージ

- リモートサービス

- 同期されたローカルキャッシュ


新しい保存方式は、既存loaderを万能repositoryへ拡張するのではなく、必要な入力をpure parserとvalidatorへ渡す別adapterとして追加する。


保存技術の都合を`Journal`、`Transaction`、`Report`へ埋め込まない。


## トランスポートとシリアル化はコントラクトであり、ドメインではありません


JSON、HTTP、FFI、WebAssembly、IPCを使う場合、domain typeとwire typeを区別する。


```text
Haskell domain value
  -> explicit transport DTO
  -> JSON / FFI / IPC
  -> frontend type
```


次を守る。


- exact quantityをJavaScriptのfloating-point numberへ暗黙変換しない

- Commodityを捨てた単一数値へBalanceを潰さない

- `Map`、`NonEmpty`、opaque constructorsの内部表現をwire contractとして露出しない

- domain constructorを直接自動deriveしたJSON shapeへ固定しない

- parse error、validation error、application errorを区別できる形にする


Transport DTOは境界の互換契約であり、domain representationとは独立にversioningできるようにする。


## フロントエンド言語は引き続きオープンです


Frontend languageやframeworkは、このpolicyでは決定しない。


候補には、型付きWeb frontend、関数型UI、native platform language、desktop toolkitなど、複数の方向があり得る。


Frontendが何であっても、会計ruleの正本はHaskell coreに置く。


同じ会計計算を各frontendへ再実装して、platformごとに意味を分岐させない。


UI固有の状態、入力途中の不完全値、表示用sorting、画面上のselectionはfrontend側に置いてよい。


検証済みTransaction、Balance、Reportなどの会計上の意味はcore側が所有する。


## ローカルとリモートの両方の展開が引き続き可能


このpolicyはserver backendを必須としない。


将来は次のどちらも選択できる。


### リモートコア


```text
frontend
  -> HTTP or IPC
  -> Haskell application
  -> h-kernel core
```


### ローカルコア


```text
frontend
  -> native / FFI / WebAssembly bridge
  -> h-kernel core
  -> local persistence adapter
```


どちらを選ぶかは、privacy、offline use、distribution、maintenance、platform toolchainを観察してから決める。


## Haskell ネイティブの境界設計


Platform neutralityのために、特定の技術文化やframework由来のlayer namesを機械的に移植しない。


次を優先する。


- ADTでapplication requestとresultの実在するcaseを表す

- smart constructorで外部入力をdomain valueへ入場させる

- pure functionでuse caseを構成する

- effectは実際に外界へ触れる狭い境界へ置く

- capabilityが必要になった場合だけ、domainに対応するeffect abstractionを導入する

- framework class hierarchyではなく、型と関数のdependency directionで境界を守る


`Repository`、`Service`、`Controller`などの名前は禁止しない。ただし、既成のarchitecture diagramを再現するためだけには導入しない。


## 進化の法則


新しいplatform対応は、一度に一つのcoherent finite sliceとして追加する。


例:


1. 入力されたアプリケーションのクエリと結果

2. 明示的なトランスポート DTO

3.JSONコーデック

4. 1 つの HTTP エンドポイント

5. 1 つのブラウザまたはモバイル アダプタ


これらを一つのPRへ混ぜない。


最初のadapterが現れる前に、存在しない全platformを想定したgeneric abstractionを作らない。


二つ目の実在するadapterが現れ、重複した意味が観察できた時点で、共有boundaryを抽出する。


## 移植性に関するレビューの質問


Applicationまたはadapterに関わるPRでは、少なくとも次を確認する。


1. この変更はdomain ruleか、delivery concernか

2. platform-specific dependencyがpure coreへ逆流していないか

3. filesystem、database、HTTP、JSONを唯一の正本として扱っていないか

4. exact quantityとCommodityが境界で失われていないか

5. domain typeとtransport DTOを不必要に同一視していないか

6. CLIの表示契約がapplication resultとして再利用されていないか

7. 新しい抽象は実在する二つ以上のcaseから得たものか

8. 将来のplatform選択を残すために、現在のcodeを過剰に複雑化していないか

9. adapterを外してもpure accounting testが成立するか

10. 同じ会計ruleを別platformへ複製していないか


## 非目標


このpolicyは次を意味しない。


- すべてのplatformをsupportすると約束すること

- 今すぐGUI、HTTP server、mobile build、WebAssemblyを追加すること

- 一つのbinaryを全platformで共有すること

- UIまでHaskellで書くこと

- frontend frameworkを今決定すること

- database abstractionを先に作ること

- native applicationよりbrowser applicationを優先すること

- remote backendよりlocal applicationを優先すること


決めるのはdelivery surfaceではなく、delivery surfaceが会計核を歪めない境界である。


## 既存の政策との関係


このpolicyは`HASKELL_NATIVE_CODE_POLICY.md`を補完する。


- Haskell-native policyは、core内部の型、関数、抽象、data flowを扱う

- Platform-neutral policyは、coreと外界のdependency directionを扱う


両方に共通する原則は、外部都合による手続き的stateや重複表現をcoreへ持ち込まず、validな値からvalidな値への変換としてdomainを読めるようにすることである。
