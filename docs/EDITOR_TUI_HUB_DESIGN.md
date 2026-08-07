# Editor TUI Hub Design Sketch

> **Status**: SKETCH
> **Role**: architecture

## 現在の実装と課題

現在の TUI アプリケーション (`editor-tui-app/Main.hs`) は、768行の単一モジュールにナビゲーション、Brickのフォーム操作、描画、ファイルI/Oなど全てが混在している。純粋な対話層 (`editor-src/HKernel/Editor/Interaction/ActualAdd.hs`) は状態遷移のみを管理しているため健全だが、Brick アダプタ層に役割が集中しすぎている。
今後 Report モードや Inspect モードなどの別機能を TUI に追加するにあたり、現状のまま拡張するとアダプタ層がスパゲッティ化する危険が高い。

## 解決策：3層アーキテクチャとADTベースのナビゲーション

以下の3層に構造を分離する。

1. **純粋 Interaction 層** (`editor-src/`): UI に依存しない型と純粋関数。既存の `ActualAdd` や新設する `Navigation` (Place ADT)、`Inspect` (ドメインクエリ) を配置。
2. **画面アダプタ層** (`editor-tui-app/TUI/`): 各画面ごとの Brick 描画・イベントハンドラ (Hub, Workspace, ActualAdd, Inspect など)。
3. **配線層** (`editor-tui-app/Main.hs`): グローバルな `UIState` を持ち、各画面アダプタにイベントをディスパッチする薄い配線。

## 実装計画 (TODO)

### Phase 0: TUI モジュール分割 (機能変更なし)
> **目標**: 既存の `Main.hs` を画面ごとのモジュールに分割し、拡張可能な基盤を作る。

- `editor-tui-app/TUI/Types.hs`: `UIState`, `AppContext`, `AppWrapper` 等の型定義
- `editor-tui-app/TUI/Workspace.hs`: 既存 Workspace の描画とイベント処理
- `editor-tui-app/TUI/ActualAdd.hs`: 既存 ActualAdd (6画面分) の描画とイベント処理
- `editor-tui-app/TUI/Common.hs`: 共通のUIパーツ
- `editor-tui-app/Main.hs`: 各サブモジュールへのディスパッチ (50行程度に縮小)

### Phase 1: ハブ導入と既存機能の再配置
> **目標**: ハブ画面を追加し、既存の Workspace と ActualAdd を壊さずに組込む。

- `editor-src/HKernel/Editor/Interaction/Navigation.hs` 新設 (`Place`, `EditPlace`, `InspectPlace`, `ReportPlace`)
- `TUI.Hub` モジュールを作成し、ハブ画面 (Workspace / Edit / Inspect / Report) の入口を作る。
- ハブの `Esc` はアプリ終了、Workspace の `Esc` はハブに戻るようにする。

### Phase 2: Inspect モード（確かめる）
> **目標**: 勘定と封筒の接続関係を TUI で確認可能にする。

- `editor-src/HKernel/Editor/Inspect.hs` 新設 (`AccountContext`, `EnvelopeContext` を導出する純粋関数)
- `AppContext` に `BudgetPolicy` と `HouseholdPolicy` を追加し、起動時に読み込む。
- 勘定一覧画面から詳細画面へ遷移し、その勘定の接続マップを表示する。

### Phase 3: Report モード（見る）
> **目標**: 既存レポート出力を TUI 内で閲覧可能にする。

- レポート種別や期間を選択する UI を追加。
- `HKernel.Report.*` の出力を Brick `viewport` に表示。

### Phase 4: Edit モード拡張
> **目標**: CLI にある操作を TUI に段階的に接続。

- `ActualReverse` (取消) の TUI 実装。
- `AccountAdd` (勘定追加) の TUI 実装。

### Phase 5: 磨き上げ
> **目標**: UX 改善とコード整理。

- キーバインド一覧画面 (`?` キー)。
- 現在の場所を示すステータスバー (例: `Hub > Edit > Actual Add`)。
