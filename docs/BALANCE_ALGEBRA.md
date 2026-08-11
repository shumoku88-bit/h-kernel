# Balanceの組合せ契約

ステータス: アクティブなdomain contract  
更新日: 2026-08-11

## 目的

この文書は、`HKernel.Money.Balance`がどのように組み合わさり、どの値には同じ抽象を広げないかを記録する。

抽象を機能一覧として配置せず、会計上すでに存在する組合せをHaskellの形で明示する。

## 値の境界

### Quantity

`Quantity`は一つの正確な10進量である。現在は`addQuantity`、`negateQuantity`などの名前付き演算を持つが、公開`Num` instanceは持たない。

### Amount

`Amount`は一つの`Commodity`と一つの`Quantity`の組である。異なるCommodityのAmountを足した結果は一つのAmountではないため、`Num`、`Semigroup`、`Monoid`を与えない。

```text
100 JPY + 2 USD
  -> Amountにはならない
  -> Balance { JPY = 100, USD = 2 }
```

### Balance

`Balance`はCommodityごとのQuantityを保持するcanonicalな多商品残高である。ゼロQuantityのentryは除去され、空mapだけがゼロBalanceを表す。

同じCommodityだけを足し、異なるCommodityを独立に保持する結合を`Semigroup`と`Monoid`として公開する。

```haskell
(<>)   :: Balance -> Balance -> Balance
mempty :: Balance
```

`addBalance`は`(<>)`と同じ意味を持つ名前付きdomain入口として残す。`sumBalances`は`fold`、`balanceFromAmounts`は`foldMap singletonBalance`である。

## 成立する法則

- 結合律: `(a <> b) <> c = a <> (b <> c)`
- 左右単位元: `mempty <> a = a` / `a <> mempty = a`
- 可換性: `a <> b = b <> a`
- 加法逆元: `a <> negateBalance a = mempty`
- zero normalization: 相殺されたCommodity entryは残らない

PostingやLedgerEntryの順序はsource側に残るが、Balanceへのprojectionは順序を忘れてよい。

## 実際の利用箇所

- `HKernel.Money.balanceFromAmounts`: AmountをBalanceへ持ち上げて`foldMap`
- `HKernel.Money.sumBalances`: Balance collectionの`fold`
- `HKernel.Ledger`: Posting collectionからTransaction balanceを`foldMap`
- `HKernel.Engine.Facts`: LedgerEntry collectionからJournal balanceを`foldMap`
- `HKernel.Report.Matrix`: coordinateごとのBalanceを`<>`で集約し、rowとcolumn totalを導出

## 同じ抽象を広げない値

値を組み合わせられそうに見えるという理由だけでinstanceを追加しない。

- `Amount`: Commodityが異なると同じ型の結果にならない
- `Transaction`: identity、description、date、Posting順序を持つ
- `Journal`と各History: source orderとprovenanceを持つ
- `BudgetEntitlement`、`BudgetConsumption`、`BudgetRemaining`: observation、cycle、policyとの整合が必要
- `AccountBalances`: Account座標のzero pruningとquery scopeを所有する

これらに組合せが必要になった場合は、対象ownerの文脈とlawを先に確認する。

## 検証

`h-kernel-balance-law-test`がSemigroup結合律、Monoid左右単位元、可換性、加法逆元、zero normalization、`addBalance`/`(<>)`一致、`sumBalances`/`fold`一致、`balanceFromAmounts`のhomomorphismをpropertyとして検査する。
