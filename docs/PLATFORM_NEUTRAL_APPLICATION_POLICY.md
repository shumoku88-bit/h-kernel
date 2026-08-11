# プラットフォームに依存しないアプリケーション ポリシー

ステータス: 承認済み  
範囲: domain/application boundaryとdelivery adapter

## 目的

特定のUI、OS、transport、storageの都合に会計核を所有させない。

```text
external input
  -> delivery adapter
  -> application/domain admission
  -> pure accounting transformation
  -> typed result
  -> delivery adapter
  -> external output
```

CLI、TUI、GUI、HTTPなどはdelivery adapterであり、会計ruleの正本ではない。

## 境界

Pure coreはAccount、Commodity、Quantity、Posting、Transaction、Journal、Report、policy、typed errorを所有する。

Delivery adapterは引数、terminal event、HTTP、JSON、window lifecycle、platform storageなど外界固有の責務を所有する。

Domain moduleからplatform adapterへ依存しない。UI固有stateや入力途中の不完全値をdomainへ逆流させない。

## Persistence

filesystem、SQLite、browser storage、remote serviceなどを唯一のdomain representationとして扱わない。新しい保存方式が必要になった場合は、既存domain/parserへ必要な値を渡すadapterとして追加する。

## Transport

wire typeとdomain typeを区別する。

- exact Quantityをfloating-pointへ暗黙変換しない
- Commodityを捨てない
- opaque constructorの内部表現をwire contractへ固定しない
- parse / validation / application errorを区別する

## 抽象化

将来のplatformを想像してgeneric repository/service/frameworkを先に作らない。実在するuse caseから必要な境界だけを追加する。

新しい抽象は、複数の実在するcaseで同じ意味が重複したときに検討する。

## Review

Applicationまたはadapter変更では次を確認する。

1. domain ruleかdelivery concernか
2. platform dependencyがcoreへ逆流していないか
3. exact QuantityとCommodityを失っていないか
4. domain typeとtransport typeを不必要に同一視していないか
5. adapterを外してもpure accounting testが成立するか
6. 同じ会計ruleを別adapterへ複製していないか

このpolicyは将来のplatform対応を約束するものではない。現在の家計簿システムを不必要に複雑化せず、delivery surfaceが会計核を歪めないことだけを要求する。
