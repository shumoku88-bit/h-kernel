{-# LANGUAGE OverloadedStrings #-}

-- | GHCup-inspired application shell over the admitted editor context.
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
  ) where

import Brick
import Brick.Widgets.Border (borderWithLabel)
import Brick.Widgets.List qualified as L
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Vector qualified as Vec

import HKernel.Editor.TUI.Home qualified as Home
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , HouseholdSection(..)
  , Name(..)
  , contextIssueCounts
  )

data ShellFocus
  = CalendarFocus
  | SectionFocus
  | SurfaceFocus
  deriving (Eq, Show)

-- | Draw one persistent shell. The calendar and major-function rail stay on
-- the left; the right side is selected-day detail while the calendar owns
-- focus, otherwise it is the selected production section surface.
draw
  :: AppContext
  -> Day
  -> ShellFocus
  -> Widget Name
  -> Widget Name
draw context selectedDay focus sectionBody =
  vBox
    [ hBox
        [ hLimit 39 (drawRail context selectedDay focus)
        , padLeft (Pad 1) (drawRightPane context selectedDay focus sectionBody)
        ]
    , padTop (Pad 1) (drawHelp focus)
    ]

drawRail :: AppContext -> Day -> ShellFocus -> Widget Name
drawRail context selectedDay focus =
  vBox
    [ Home.drawCalendarWithFocus (focus == CalendarFocus) context selectedDay
    , padTop (Pad 1) (drawSectionRail context focus)
    , fill ' '
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

drawHelp :: ShellFocus -> Widget Name
drawHelp focus = withAttr (attrName "shellMuted") (strWrap message)
  where
    message = case focus of
      CalendarFocus ->
        "Calendar: arrows/hjkl move day · t today · r record · Tab next focus · Shift-Tab previous focus · q quit"
      SectionFocus ->
        "Sections: Up/Down or j/k select · Right/Enter surface · Left calendar · Tab/Shift-Tab focus · q quit"
      SurfaceFocus ->
        "Surface: section owns arrows and local keys · Tab next focus · Shift-Tab sections · q quit"

focusLabel :: Bool -> Text -> Widget Name
focusLabel focused label
  | focused = withAttr (attrName "shellFocus") (txt ("[" <> label <> "]"))
  | otherwise = txt label

sectionStatus :: AppContext -> HouseholdSection -> (Text, AttrName, Text)
sectionStatus context section = case section of
  ActualSection -> ordinary (countOf (contextWorkspaceList context) <> " rec")
  PlansSection -> ordinary (countOf (contextPlanList context) <> " open")
  EntitlementSection -> ordinary "observe"
  AccountsSection -> ordinary (T.pack (show accountCount))
  IssuesSection
    | openIssues == 0 -> ("✓", attrName "success", "clear")
    | otherwise -> ("!", attrName "warning", T.pack (show openIssues) <> " open")
  ReportsSection -> ordinary "ready"
  SettingsSection -> ordinary "ready"
  where
    ordinary summary = ("✓", attrName "success", summary)
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
