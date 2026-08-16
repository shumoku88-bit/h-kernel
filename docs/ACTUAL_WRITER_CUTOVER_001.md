# Actual Journal writer contract

ステータス: 承認済みcurrent contract  
Owner: `actual.journal`固有のrollback / reader boundary  
更新日: 2026-08-17

## 1. この文書の役割

`actual.journal`のcurrent writer authorityそのものは[`WRITER_AUTHORITY.md`](WRITER_AUTHORITY.md)が所有する。safe publication lawは[`EDITOR_DEVELOPMENT_PLAN.md`](EDITOR_DEVELOPMENT_PLAN.md)とEditor implementation ownerが所有する。

この文書は、一般lawへ重複させる必要のない`actual.journal`固有のrollbackとreader compatibilityだけを追加する。daily command一覧、完了済みcutover手順、過去のactivation evidenceは所有しない。それらはcurrent entrypointまたはGit履歴から確認する。

## 2. Actual固有のrollback

`actual.journal`のwriter authorityを別implementationへ戻す場合、自動fallbackやalternating writeにはしない。

1. `h-kernel`と移動先候補の両writer operationを停止する。
2. canonical `actual.journal`のcurrent bytesを保全する。
3. current sourceがstrict Actual admissionを通ることを確認する。
4. 未完了preview、publication、restore operationがないことを確認する。
5. 移動先reader / writerがcurrent Actual source contractをadmitできることを確認する。
6. 作者がwriter authorityの再移動を明示承認する。
7. [`WRITER_AUTHORITY.md`](WRITER_AUTHORITY.md)のcurrent authorityを更新した後にだけ新しいwriterを開始する。

source rollbackとwriter authority rollbackを暗黙に同時実行しない。rollback中も同一canonical sourceへ複数writerを向けない。

## 3. Reader compatibility

writer authorityとreader compatibilityは別の契約である。

`h-kernel`以外のreaderをcanonical `actual.journal`へ向ける場合、そのreaderは現在のActual source contractをsilent ignoreなしにadmitできなければならない。特にreversalはdurable `event-id`とexplicit `reverses` relationを持つため、reader compatibilityのためにh-kernel側のidentity / provenance contractを弱めない。

reversal identityのcurrent lawは[`ACTUAL_REVERSE_PROVENANCE_DECISION_001.md`](ACTUAL_REVERSE_PROVENANCE_DECISION_001.md)が所有する。

## 4. 所有しないもの

- current daily command surface
- Editor UI / TUI interaction
- generic safe publication law
- source別の一般single-writer lawとcutover gate
- private source format migration
- 他canonical sourceのwriter authority

これらはそれぞれcurrent implementation、[`EDITOR_DEVELOPMENT_PLAN.md`](EDITOR_DEVELOPMENT_PLAN.md)、[`WRITER_AUTHORITY.md`](WRITER_AUTHORITY.md)、source contractのownerに従う。
