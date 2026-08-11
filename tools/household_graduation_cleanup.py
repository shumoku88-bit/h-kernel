from pathlib import Path


def replace_exact(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"expected text not found in {path}: {old!r}")
    p.write_text(text.replace(old, new, 1))


replace_exact(
    "README.md",
    "household-src/   stable household policy and admissions\neditor-src/      editor intent, candidate, safe writer\nspike-src/       provisional Household Report composition\n",
    "household-src/   stable household policy, admissions and pure Report composition\nhousehold-app-src/ canonical Household IO and admission bootstrap\neditor-src/      editor intent, candidate, safe writer\n",
)

replace_exact(
    "docs/ARCHITECTURE.md",
    "    AccountProfile admission, HouseholdPolicy, DailyTarget,\n    HouseholdBacking, BudgetMovement, Household Issue admission\n",
    "    AccountProfile admission, HouseholdPolicy, DailyTarget,\n    HouseholdBacking, BudgetMovement, Household Issue admission,\n    pure Household Report composition and rendering\n",
)
replace_exact(
    "docs/ARCHITECTURE.md",
    "h-kernel-household-application\n  source: spike-src/\n  depends on: h-kernel + h-kernel-household\n  owns:\n    provisional Household Report composition and rendering\n",
    "h-kernel-household-application\n  source: household-app-src/\n  depends on: h-kernel + h-kernel-household\n  owns:\n    canonical Household source IO, typed admission, HouseholdState,\n    write snapshots and pure Report composition bootstrap\n",
)

replace_exact(
    "docs/CODE_MAP_AND_DESIGN_SKETCH.md",
    "| `household-src/` | Account profile admission、Household policy、Daily Target、Backing、Budget movement、Issue admission | stable library |\n| `editor-src/` | typed edit intent、candidate preparation、source placement、safe writer、Actual workspace projection、UI-independent interaction | stable editor library |\n| `spike-src/` | stable typed ownerを合成するHousehold Report compositionとrendering | active spike |\n",
    "| `household-src/` | Account profile admission、Household policy、Daily Target、Backing、Budget movement、Issue admission、pure Household Report composition/rendering | stable library |\n| `household-app-src/` | canonical Household source IO、typed admission、HouseholdState、write snapshot、Report bootstrap | stable application library |\n| `editor-src/` | typed edit intent、candidate preparation、source placement、safe writer、Actual workspace projection、UI-independent interaction | stable editor library |\n",
)
replace_exact(
    "docs/CODE_MAP_AND_DESIGN_SKETCH.md",
    "  owns: AccountProfile, HouseholdPolicy, DailyTarget,\n        HouseholdBacking, BudgetMovement, Issue admission\n",
    "  owns: AccountProfile, HouseholdPolicy, DailyTarget,\n        HouseholdBacking, BudgetMovement, Issue admission,\n        pure Household Report composition and rendering\n",
)
replace_exact(
    "docs/CODE_MAP_AND_DESIGN_SKETCH.md",
    "h-kernel-household-application\n  source: spike-src/\n  depends on: h-kernel + h-kernel-household\n  owns: provisional Household Report composition\n",
    "h-kernel-household-application\n  source: household-app-src/\n  depends on: h-kernel + h-kernel-household\n  owns: canonical Household IO, typed admission, HouseholdState,\n        write snapshots and Report bootstrap\n",
)

replace_exact(
    "docs/ARCHITECTURE_CODE_QUALITY_REVIEW.md",
    "| `h-kernel-household` | `household-src/` (~10 files) | 世帯固有: 予算、日次目標、勘定プロファイル | なし |\n| `h-kernel-editor` | `editor-src/` (~14 files) | 編集: 型付き編集意図、プレビュー、安全な原子的書込み | 書込みのみ |\n| `h-kernel-spike-*` | `spike-src/` (~3 files) | レポート構成の実験 | — |\n",
    "| `h-kernel-household` | `household-src/` | 世帯固有: 予算、日次目標、勘定プロファイル、pure Report composition/rendering | なし |\n| `h-kernel-household-application` | `household-app-src/` | canonical Household IO、typed admission、write snapshot、Report bootstrap | 読込み |\n| `h-kernel-editor` | `editor-src/` (~14 files) | 編集: 型付き編集意図、プレビュー、安全な原子的書込み | 書込みのみ |\n",
)

replace_exact(
    "h-kernel.cabal",
    "    build-depends:    base >= 4.14 && < 5\n          , containers >= 0.6 && < 0.8\n          , h-kernel\n          , h-kernel-household\n          , text >= 1.2 && < 2.2\n          , time >= 1.9 && < 1.15\n",
    "    build-depends:    base >= 4.14 && < 5\n                    , containers >= 0.6 && < 0.8\n                    , h-kernel\n                    , h-kernel-household\n                    , text >= 1.2 && < 2.2\n                    , time >= 1.9 && < 1.15\n",
)

replace_exact(
    "tests/HouseholdReportSpec.hs",
    "        (\"Status: NOT AVAILABLE\" `T.isInfixOf` shortPreviousRendered\n&& \"Daily Target\" `T.isInfixOf` shortPreviousRendered\n&& \"Envelope & Backing\" `T.isInfixOf` shortPreviousRendered)\n",
    "        (\"Status: NOT AVAILABLE\" `T.isInfixOf` shortPreviousRendered\n          && \"Daily Target\" `T.isInfixOf` shortPreviousRendered\n          && \"Envelope & Backing\" `T.isInfixOf` shortPreviousRendered)\n",
)
