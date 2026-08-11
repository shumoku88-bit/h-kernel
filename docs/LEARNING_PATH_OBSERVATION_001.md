# h-kernel learning path observation 001

ステータス: OBSERVATION ONLY  
観察日: 2026-08-11

## 目的

`h-kernel` の Cabal public surface を、そのまま学習順序だと扱わない。

[`PUBLIC_MODULE_SURFACE_OBSERVATION_001.md`](PUBLIC_MODULE_SURFACE_OBSERVATION_001.md) では、現在の 65 exposed modules が accidental export-all や明白な orphan 集合ではないことを確認した。一方、Cabal visibility は「どの module を package consumer が import できるか」を表すだけで、作者または学習者がどこから読むべきかは表さない。

この観察では、最初の数 module だけに範囲を絞り、次を問う。

> h-kernel を Haskell の実用品・教材として読み始めるとき、どの順序なら domain meaning と Haskell meaning が同時に見え、難しさが段階的に増えるか。

これは curriculum の確定ではない。module の移動、re-export、Cabal exposure、API、test、production code は変更しない。

## 観察対象

最初の候補として次を読んだ。

- `HKernel.Period`
- `HKernel.Account`
- `HKernel.Money`
- `HKernel.Ledger`
- `HKernel.Journal`
- `HKernel.Account.Journal`
- `HKernel.Engine`
- `tests/BalanceLawSpec.hs`
- `tests/Spec.hs`
- `docs/BALANCE_ALGEBRA.md`

比較した座標は次である。

- domain 上の中心性
- 前提となる h-kernel module
- source size と局所的な読みやすさ
- hidden constructor / smart constructor が何を守るか
- ADT、`Maybe`、`Either`、`Map`、`NonEmpty` などの導入密度
- `Semigroup` / `Monoid` / `Foldable` などの抽象が domain law と対応しているか
- effect / parsing / source coordinate がどの段階で入るか
- test が実装の意味を教材として補助するか

## 1. `HKernel.Period`: 任意の序曲

`HKernel.Period` は 39 行の小さい owner である。

```haskell
data Period = Period
  { periodStart        :: Day
  , periodEndExclusive :: Day
  }

mkPeriod :: Day -> Day -> Either PeriodError Period
```

ここでは次が一度に見える。

- constructor を隠す
- invalid state を smart constructor で拒否する
- domain failure を `Either` で型に出す
- half-open interval `[start, endExclusive)` を pure predicate で使う
- persisted cycle identity や recurrence と「観察期間」を混同しない

依存は `Data.Time.Calendar.Day` だけで、会計や source parser の知識を要求しない。

### 教材上の位置

最初の必須章というより、**h-kernel の設計文法を短時間で試す序曲**として優れている。

ここだけで、project 全体に繰り返し現れる

```text
raw coordinates
  -> smart constructor
  -> validated opaque value
  -> pure observation
```

という形を観察できる。

ただし Account、Amount、Posting、Transaction の話はまだ出ないため、h-kernel の会計世界への主入口にはしない。

## 2. `HKernel.Account`: 会計世界への第一入口

`HKernel.Account` は 131 行で、Account identity と明示的 accounting metadata を所有する。

最初に `newtype Account` があり、次に `AccountType` ADT、hidden `AccountDeclaration`、`Maybe Commodity`、`AccountRegistry` の `Map`、duplicate rejection の `Either` が出る。

```text
Text
  -> Account
  -> AccountDeclaration
  -> AccountRegistry
```

特に教材として重要なのは、名前と意味を分けている点である。

```text
Account name      = identity
AccountType       = declared accounting meaning
name prefix       ≠ accounting meaning
```

これは型の使い方だけでなく、h-kernel の accounting philosophy を早い段階で示す。

### Haskell の段階

ここで自然に読める概念は次である。

- `newtype`
- ADT と pattern-free construction
- hidden constructor
- smart constructor
- `Maybe`
- `Map`
- `Either`
- `<$>` による小さな projection

`HKernel.Account` は `HKernel.Money` から `Commodity` 型だけを import する。したがって compiler dependency は `Money -> Account` だが、読者は最初は `Commodity` を opaque な「商品識別子」として受け取り、次章でその owner を開くことができる。

このため **dependency order と pedagogical order は同一でなくてよい**。

## 3. `HKernel.Money`: exact arithmetic から lawful algebra へ

`HKernel.Money` は h-kernel 内部 module に依存しない。compiler dependency graph では最も基礎に近い。

しかし 192 行の中で扱う Haskell の密度は `Account` より高い。

```text
Commodity
Quantity
Amount
Balance
```

が順に現れ、最後に `Balance` の algebra へ進む。

重要な設計は次である。

- `Quantity` は `Scientific` による exact decimal
- `Amount` は exactly one `Commodity` + `Quantity`
- `Amount` に `Num` を与えない
- 異 Commodity の値は `Balance` で別座標のまま保持する
- `Balance` は zero entry を除去した canonical representation
- `Balance` の結合だけに `Semigroup` / `Monoid` を与える
- `balanceFromAmounts` は `foldMap singletonBalance`
- `sumBalances` は `fold`

つまり typeclass は Haskell 機能の展示として登場するのではなく、先に存在する会計上の結合 law に名前を与える。

### なぜ `Account` の後がよいか

`Money` から始めると、opaque value、exact arithmetic、canonicalization、typeclass law が最初から重なる。

`Account` で

```text
identity -> validated declaration -> registry
```

という型設計に慣れた後なら、`Money` の

```text
single coordinate -> canonical multi-coordinate value -> lawful composition
```

という一段高度な話が見えやすい。

## 4. `tests/BalanceLawSpec.hs`: `Money` とセットで読む

`BalanceLawSpec` は `Money` の後に読む価値が高い。

ここでは QuickCheck により次を観察する。

- Semigroup associativity
- Monoid left/right identity
- commutativity
- additive inverse
- zero normalization
- `addBalance` と `(<>)` の一致
- `sumBalances` と `Foldable.fold` の一致
- `balanceFromAmounts` が collection concatenation を Balance composition へ写すこと

最後の property は特に重要である。

```haskell
balanceFromAmounts (left ++ right)
  == balanceFromAmounts left <> balanceFromAmounts right
```

これは `foldMap` が単なる短縮記法ではなく、Amount collection と Balance algebra の対応そのものだと示す。

`docs/BALANCE_ALGEBRA.md` も同じ law を domain language で説明しているため、

```text
Money.hs
  <-> BALANCE_ALGEBRA.md
  <-> BalanceLawSpec.hs
```

の三面で読むと、code / domain contract / executable evidence が対応する。

## 5. `HKernel.Ledger`: 二つの基礎 owner を合成する

`HKernel.Ledger` は 128 行で `Account` と `Money` を直接合成する。

ここで初めて複式簿記の Transaction invariant が一つの型境界へ集まる。

```text
Account + Amount
  -> Posting

Day + nonblank description + at-least-two Postings
  -> balanced Transaction
```

教材上、次の Haskell が自然に現れる。

- hidden `TransactionDescription`
- hidden `Postings`
- `NonEmpty`
- runtime check だけでなく representation で「2 postings 以上」を保持する ADT
- `Either TransactionError`
- `do` notation による dependent validation
- `foldMap (singletonBalance . postingAmount)`
- validated `Transaction` constructor の非公開

`Money` で学んだ Balance algebra が、ここでは

```haskell
postingCollectionBalance =
  foldMap (singletonBalance . postingAmount)
```

として実際の double-entry invariant へ接続される。

したがって `Ledger` は `Money` の抽象が家計簿の意味へ戻ってくる地点である。

## 6. `HKernel.Journal` は次の「一 module」には大きすぎる

`HKernel.Journal` は現在 703 行あり、単純な parser introduction ではない。

前半だけでも次が同時に現れる。

- include syntax
- unresolved `JournalDocument` と validated `Journal` の区別
- source line / quantity-column coordinate
- transaction metadata
- Account registry
- Posting / Transaction admission
- parser-local `ParsedBlock`
- partial posting
- typed diagnostic
- `Applicative` な include resolution
- source order と domain value の対応

これは悪い複雑さではない。むしろ Journal が現在所有している source evidence が多いことの表れである。

しかし `Ledger` の直後に 703 行を上から順に読むと、学習者は

```text
domain invariant
```

から突然

```text
syntax + coordinates + provenance + admission + parser mechanics
```

へ移る。

そのため現時点では、`Journal` を「第4 module」と固定しない。

### `HKernel.Account.Journal` を先にしない理由

`HKernel.Account.Journal` は 181 行と小さいが、ordinary `HKernel.Journal` を single syntax owner として再利用する source-specific adapter である。

先に読むと、なぜ parser を再実装せず `parseJournal` を使うのかという ownership の意味がまだ見えない。

したがって size だけで reading order を決めない。

## 7. `HKernel.Engine` は facade の教材であって第一入口ではない

`HKernel.Engine` 自体は 25 行で小さい。

しかし実装を `HKernel.Engine.Facts` へ隠し、public module は stable facade として export surface を定義する。

これは module ownership、internal representation hiding、public API design の良い教材である。

一方、「小さいから最初に読む」と中核計算が見えない。

したがって LOC の小ささと pedagogical simplicity も同一ではない。

## 8. `tests/Spec.hs` の順序は curriculum ではない

現在の統合的な `tests/Spec.hs` は `money tests` から始まり、Account、Journal、Engine、Report へ進む。

これは current system の executable evidence として有用だが、歴史的に育った test runner の順序を、そのまま作者向け learning path とみなさない。

特に `BalanceLawSpec` のような focused law test の方が、`Money` の abstraction を学ぶ companion として明瞭である。

## 第一観察の結論

現時点で最も自然に見える最初の reading movement は次である。

```text
optional overture
  HKernel.Period
      |
      v
main entry
  HKernel.Account
      |
      v
  HKernel.Money
      |
      +--> docs/BALANCE_ALGEBRA.md
      +--> tests/BalanceLawSpec.hs
      |
      v
  HKernel.Ledger
```

### この順序で見えるもの

`Period`:
- opaque validated value
- smart constructor
- `Either`

`Account`:
- identity と meaning の分離
- `newtype`, ADT, `Maybe`, `Map`, `Either`

`Money`:
- exact decimal
- canonical representation
- domain-fit `Semigroup` / `Monoid`
- `fold` / `foldMap`

`Ledger`:
- `NonEmpty`
- stronger internal ADT
- dependent validation with `do`
- Balance algebra から Transaction invariant への合成

この progression は「Haskell 機能を簡単な順に並べる」ものではない。

```text
domain meaning
  -> 必要な type boundary
  -> 対応する Haskell structure
  -> executable law / invariant
```

の密度を少しずつ上げる。

## dependency order と learning order

compiler dependency は概ね次である。

```text
Money -> Account
Money + Account -> Ledger
```

第一観察の learning order は次である。

```text
Account -> Money -> Ledger
```

これは矛盾ではない。

`Account` が `Money` から必要とするのは `Commodity` 型であり、最初は opaque coordinate として受け取れる。次に `Money` を読むことで、その coordinate の validation と exact arithmetic を開く。

したがって今回さらに次の区別が必要だと分かった。

```text
reachability
Cabal visibility
compiler dependency
pedagogical order
```

これらは四つの異なる座標である。

## Decision

- Cabal exposure は変更しない。
- module の移動や re-export facade を learning path のために追加しない。
- `HKernel.Period` を optional design prelude として観察上 retain する。
- h-kernel の会計世界への第一候補は `HKernel.Account` とする。
- `HKernel.Money` は `BALANCE_ALGEBRA.md` と `BalanceLawSpec` を companion として読む候補とする。
- `HKernel.Ledger` を、Account identity と Money algebra が double-entry invariant へ合流する最初の culmination とする。
- `HKernel.Journal` 以降の順序は今回確定しない。
- `tests/Spec.hs` の実行順を curriculum とみなさない。
- source size、dependency order、public visibility のどれか一つだけで learning order を決めない。

## 次の問い

第一楽章の後、source text から validated accounting meaning へ移る最初の教材をどう置くべきか。

候補は少なくとも次である。

1. `Journal` 全体を読む前に parser / validation / source evidence を小さな概念単位で案内する。
2. `JournalDocument -> Journal` という unresolved / validated 境界を中心に読む。
3. `Account.Journal` や `Plan.Journal` の source-specific admission を、ordinary Journal ownership を理解した後の比較教材にする。
4. source admission より先に `Engine` / Report projection へ進み、validated values の pure transformation を先に学ぶ。

次の observation ではこの分岐を比較し、まだ実装・module split・curriculum 化へ飛ばない。
