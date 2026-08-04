# Balanceの組合せ契約

ステータス: アクティブなdomain contract  
更新日: 2026-08-04

## 目的

この文書は、`HKernel.Money.Balance`がどのように組み合わさり、どの値には同じ抽象を広げないかを記録する。

抽象を教材上の機能一覧として配置するのではなく、会計上すでに存在する組合せをHaskellの形で明示する。

## 値の境界

### Quantity

`Quantity`は一つの正確な10進量である。現在は`addQuantity`、`negateQuantity`などの名前付き演算を持つが、公開`Num` instanceは持たない。

### Amount

`Amount`は一つの`Commodity`と一つの`Quantity`の組である。

異なるCommodityのAmountを足した結果は、もはや一つのAmountではない。そのため、`Amount`には`Num`、`Semigroup`、`Monoid`を与えない。

```text
100 JPY + 2 USD
  -> Amountにはならない
  -> Balance { JPY = 100, USD = 2 }
```

### Balance

`Balance`はCommodityごとのQuantityを保持するcanonicalな多商品残高である。ゼロQuantityのentryはすべてのconstructorと演算で除去され、空mapだけがゼロBalanceを表す。

`Balance`の結合は、同じCommodityだけを足し、異なるCommodityを独立に保持する。この結合には文脈や順序を必要としないため、`Semigroup`と`Monoid`として公開する。

```haskell
(<>)   :: Balance -> Balance -> Balance
mempty :: Balance
```

`addBalance`は`(<>)`と同じ意味を持つ名前付きdomain入口として残す。`sumBalances`は`fold`、`balanceFromAmounts`は`foldMap singletonBalance`である。

## 成立する法則

`Balance`は`(<>)`について次を満たす。

### 結合律

```text
(a <> b) <> c = a <> (b <> c)
```

### 左右の単位元

```text
mempty <> a = a
a <> mempty = a
```

### 可換性

```text
a <> b = b <> a
```

PostingやLedgerEntryの順序はsource側に残るが、Balanceへのprojectionは順序を忘れてよい。

### 加法逆元

```text
a <> negateBalance a = mempty
```

`negateBalance`を含めると、Balanceは可換な加法群として振る舞う。差は`subtractBalance left right = left <> negateBalance right`として定義する。

### ゼロ正規化

Quantityが相殺されたCommodity entryは残らない。

```text
balanceEntries (a <> negateBalance a) = []
```

この正規化により、同じ会計値が複数の内部表現を持たない。

## 実際の利用箇所

- `HKernel.Money.balanceFromAmounts`: AmountをBalanceへ持ち上げて`foldMap`
- `HKernel.Money.sumBalances`: Balance collectionの`fold`
- `HKernel.Ledger`: Posting collectionからTransaction balanceを`foldMap`
- `HKernel.Engine.Facts`: LedgerEntry collectionからJournal balanceを`foldMap`
- `HKernel.Report.Matrix`: coordinateごとのBalanceを`<>`で集約し、rowとcolumn totalを`fold` / `foldMap`で導出

## 同じ抽象を広げない値

この契約は、値を組み合わせられそうに見えるという理由だけでinstanceを追加する許可ではない。

現在、次には組合せinstanceを追加しない。

- `Amount`: Commodityが異なると同じ型の結果にならない
- `Transaction`: identity、description、date、Posting順序を持つ
- `Journal`と各History: source orderとprovenanceを持つ
- `BudgetEntitlement`、`BudgetConsumption`、`BudgetRemaining`: observation、cycle、policyとの整合が必要
- `AccountBalances`: Account座標のzero pruningとquery scopeを所有し、公開結合の意味をまだ確定していない

これらに組合せが必要になった場合は、対象ownerの文脈とlawを先に観察する。

## 検証

`h-kernel-balance-law-test`が、三つのCommodityを持つ生成値に対して次をpropertyとして検査する。

- Semigroup結合律
- Monoid左右単位元
- 可換性
- 加法逆元
- zero normalization
- `addBalance`と`(<>)`の一致
- `sumBalances`と`fold`の一致
- `balanceFromAmounts`がcollection concatenationをBalance結合へ写すこと

example test、Report contract、canonical Report verificationは、抽象導入前後で観察可能な会計結果が変わらないことを確認する。
