{-# LANGUAGE OverloadedStrings #-}

-- | Production application shell over the admitted editor context.
--
-- The shell owns presentation focus only. Calendar observations and section
-- surfaces remain projections of the shared 'AppContext'; no Household facts
-- are created or reinterpreted here.
module HKernel.Editor.TUI.Shell
  ( ShellFocus(..)
  , draw
  , moveSection
  , nextFocus
  , previousFocus
  , shellUsesStackedLayout
  ) where

import Brick
import Brick.Types (availWidthL, getContext)
import Brick.Widgets.Border (borderWithLabel)
import Brick.Widgets.List qualified as L
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Vector qualified as Vec
import Lens.Micro ((^.))

import HKernel.Editor.TUI.Home qualified as Home
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , HouseholdSection(..)
  , Name(..)
  , contextIssueCounts
  , contextOpenPlanObservation
  )

data ShellFocus
  = CalendarFocus
  | SectionFocus
  | SurfaceFocus
  deriving (Eq, Show)

-- | Draw one persistent shell. Wide terminals keep the calendar/function rail
-- beside the selected surface. Narrow terminals stack the same two regions so
-- the production TUI remains usable in split panes without changing semantics.
draw
  :: AppContext
  -> Day
  -> ShellFocus
  -> Widget Name
  -> Widget Name
draw context selectedDay focus sectionBody =
  vBox
    [ responsiveWhen shellUsesStackedLayout compactLayout wideLayout
    , padTop (Pad 1) (drawHelp context focus)
    ]
  where
    rail = hLimit 39 (drawRail context selectedDay focus)
    right = drawRightPane context selectedDay focus sectionBody
    wideLayout = hBox [rail, padLeft (Pad 1) right]
    compactLayout = vBox [rail, padTop (Pad 1) right]

-- | Keep the old Home width breakpoint as the application-shell breakpoint.
-- At 87 columns the 39-column rail, gap, and useful right surface fit together.
shellUsesStackedLayout :: Int -> Bool
shellUsesStackedLayout width = width < 87

-- | The shell body must be vertically greedy so Brick allocates fixed-height
-- help below it first. A vertically Fixed body containing @padBottom Max@ can
-- otherwise consume the terminal height and push the focus help off-screen.
responsiveWhen :: (Int -> Bool) -> Widget name -> Widget name -> Widget name
responsiveWhen useCompact compact wide =
  Widget Greedy Greedy $ do
    context <- getContext
    render $
      if useCompact (context ^. availWidthL)
        then compact
        else wide

drawRail :: AppContext -> Day -> ShellFocus -> Widget Name
drawRail context selectedDay focus =
  vBox
    [ Home.drawCalendarWithFocus (focus == CalendarFocus) context selectedDay
    , padTop (Pad 1) (drawSectionRail context focus)
    ]

drawSectionRail :: AppContext -> ShellFocus -> Widget Name
drawSectionRail context focus =
  borderWithLabel (focusLabel (focus == SectionFocus) label)
    (padAll 1 (vBox (map drawRow [minBound .. maxBound])))
  where
    label = "Household · current " <> T.pack
      (formatTime defaultTimeLocale "%Y-%m-%d" (contextObservationDay context))
    drawRow section =
      clickable (SectionTab section) rendered
      where
        (glyph, statusAttr, summary) = sectionStatus context section
        row = hBox
          [ hLimit 2 (withAttr statusAttr (txt glyph))
          , hLimit 11 (txt (sectionLabel section))
          , padLeft (Pad 1) (txt summary)
          ]
        rendered
          | contextCurrentSection context == section =
              withAttr (attrName "activeTab") row
          | otherwise = row

drawRightPane
  :: AppContext
  -> Day
  -> ShellFocus
  -> Widget Name
  -> Widget Name
drawRightPane context selectedDay focus sectionBody = case focus of
  CalendarFocus -> Home.drawDayPaneFull context selectedDay
  SectionFocus -> drawSectionSurface False sectionBody
  SurfaceFocus -> drawSectionSurface True sectionBody

drawSectionSurface :: Bool -> Widget Name -> Widget Name
drawSectionSurface focused body =
  vBox
    [ withAttr (if focused then attrName "shellFocus" else attrName "shellMuted")
        (strWrap (if focused
          then "[Surface] interaction focus"
          else "Surface · press Right/Enter or Tab to interact"))
    , padTop (Pad 1) (padBottom Max body)
    ]

drawHelp :: AppContext -> ShellFocus -> Widget Name
drawHelp context focus = withAttr (attrName "shellMuted") (strWrap message)
  where
    message = case focus of
      CalendarFocus ->
        "Calendar: arrows/hjkl move day · t current observation · r record · Enter selected→current change / finish marked range · Space mark or replace FROM · Esc clear FROM · click day/select FROM · wheel day details · Tab/Shift-Tab focus · q quit"
      SectionFocus ->
        "Sections: Up/Down or j/k select · click section · Right/Enter surface · Left calendar · Tab/Shift-Tab focus · q quit"
      SurfaceFocus -> surfaceHelp context

surfaceHelp :: AppContext -> String
surfaceHelp context = case contextCurrentSection context of
  ReportsSection ->
    "Reports: Enter choose · a account balances · b balance sheet · p P&L · d daily flow · m monthly · c cycle · t daily target · e envelope/backing · [ / ] previous/next · arrows/wheel scroll · Shift+wheel or Shift+←→ horizontal · PgUp/PgDn page · Home/End top/bottom · Tab/Shift-Tab focus · q quit"
  _ ->
    "Surface: pane controls are listed above · click selectable rows · wheel scroll/move · Tab next focus · Shift-Tab sections · q quit"

focusLabel :: Bool -> Text -> Widget Name
focusLabel focused label
  | focused = withAttr (attrName "shellFocus") (txt ("[" <> label <> "]"))
  | otherwise = txt label

sectionStatus :: AppContext -> HouseholdSection -> (Text, AttrName, Text)
sectionStatus context section = case section of
  ActualSection -> ordinary (countOf (contextWorkspaceList context) <> " rec")
  PlansSection -> case contextOpenPlanObservation context of
    Left _ -> unavailable "unavailable"
    Right plans -> ordinary (T.pack (show (length plans)) <> " open")
  EntitlementSection -> ordinary "observe"
  AccountsSection -> ordinary (T.pack (show accountCount))
  IssuesSection
    | openIssues == 0 -> ("✓", attrName "success", "clear")
    | otherwise -> ("!", attrName "warning", T.pack (show openIssues) <> " open")
  ReportsSection -> ordinary "ready"
  SettingsSection -> ordinary "ready"
  where
    ordinary summary = ("·", attrName "shellMuted", summary)
    unavailable summary = ("?", attrName "warning", summary)
    countOf = T.pack . show . Vec.length . L.listElements
    accountCount = Vec.length
      (Vec.filter isJust (L.listElements (contextWorkspaceAccounts context)))
    (openIssues, _) = contextIssueCounts context

sectionLabel :: HouseholdSection -> Text
sectionLabel section = case section of
  ActualSection -> "Actual"
  PlansSection -> "Plans"
  EntitlementSection -> "Envelopes"
  AccountsSection -> "Accounts"
  IssuesSection -> "Issues"
  ReportsSection -> "Reports"
  SettingsSection -> "Settings"

nextFocus :: ShellFocus -> ShellFocus
nextFocus focus = case focus of
  CalendarFocus -> SectionFocus
  SectionFocus -> SurfaceFocus
  SurfaceFocus -> CalendarFocus

previousFocus :: ShellFocus -> ShellFocus
previousFocus focus = case focus of
  CalendarFocus -> SurfaceFocus
  SectionFocus -> CalendarFocus
  SurfaceFocus -> SectionFocus

moveSection :: Int -> HouseholdSection -> HouseholdSection
moveSection delta section = toEnum nextIndex
  where
    sectionCount = fromEnum (maxBound :: HouseholdSection) + 1
    nextIndex = (fromEnum section + delta) `mod` sectionCount