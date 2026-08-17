{-# LANGUAGE OverloadedStrings #-}

-- | Quiet calendar-first observation of one admitted Household.
--
-- This module owns no Household facts. It renders pure projections from the
-- shared editor workspace boundary onto a month matrix and selected-day pane.
module HKernel.Editor.TUI.Home
  ( HomeAction(..)
  , draw
  , handleLocalEvent
  ) where

import Brick
import Brick.Widgets.Border (borderWithLabel)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Calendar
  ( Day
  , addDays
  , fromGregorian
  , gregorianMonthLength
  , toGregorian
  )
import Data.Time.Calendar.WeekDate (toWeekDate)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Graphics.Vty qualified as V

import HKernel.Account (accountName)
import HKernel.Editor.HouseholdWorkspace
  ( homeActualTransactionsOn
  , homeCycleEndDay
  , homeIssuesDueOn
  , homePlannedTransactionsOn
  )
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , Name(..)
  , contextHouseholdState
  )
import HKernel.Household.Application (HouseholdState(..))
import HKernel.Household.Report (HouseholdReportSurface)
import HKernel.HouseholdIssue
  ( HouseholdIssue
  , householdIssueAmount
  , householdIssueText
  )
import HKernel.Ledger
  ( Posting
  , Transaction
  , postingAccount
  , postingAmount
  , transactionDescription
  , transactionPostings
  )
import HKernel.Money
  ( Amount
  , amountCommodity
  , amountQuantity
  , commodityCode
  , renderQuantity
  )
import HKernel.Plan
  ( CommittedOutgoingPlan
  , committedPlanAmount
  , committedPlanMemo
  , positiveAmountValue
  )
import HKernel.Report.Config (reportConfigurationPresentation)
import HKernel.Report.Presentation
  ( CalendarMarker
  , CalendarMarkers(..)
  , calendarMarkerValue
  , presentationCalendarMarkers
  , selectCalendarMarker
  )

data HomeAction
  = HomeMaintain
  | HomeSelectDay Day
  | HomeRecord Day
  deriving (Eq, Show)

-- | Handle only interaction local to the calendar surface. Application-shell
-- navigation (Home/section tabs, quit, section-number keys) remains in Main.
handleLocalEvent
  :: Day
  -> BrickEvent Name AppEvent
  -> EventM Name AppContext HomeAction
handleLocalEvent selectedDay event = case event of
  MouseDown (CalendarDay day) V.BLeft _ _ -> selectDay day
  MouseDown HomeDayViewport V.BScrollUp _ _ -> do
    vScrollBy (viewportScroll HomeDayViewport) (-3)
    pure HomeMaintain
  MouseDown HomeDayViewport V.BScrollDown _ _ -> do
    vScrollBy (viewportScroll HomeDayViewport) 3
    pure HomeMaintain
  VtyEvent (V.EvKey V.KLeft []) -> selectDay (addDays (-1) selectedDay)
  VtyEvent (V.EvKey V.KRight []) -> selectDay (addDays 1 selectedDay)
  VtyEvent (V.EvKey V.KUp []) -> selectDay (addDays (-7) selectedDay)
  VtyEvent (V.EvKey V.KDown []) -> selectDay (addDays 7 selectedDay)
  VtyEvent (V.EvKey (V.KChar 't') []) -> today
  VtyEvent (V.EvKey (V.KChar 'T') []) -> today
  VtyEvent (V.EvKey (V.KChar 'r') []) -> pure (HomeRecord selectedDay)
  VtyEvent (V.EvKey (V.KChar 'R') []) -> pure (HomeRecord selectedDay)
  _ -> pure HomeMaintain
  where
    selectDay day = do
      vScrollToBeginning (viewportScroll HomeDayViewport)
      pure (HomeSelectDay day)
    today = do
      context <- get
      selectDay (contextObservationDay context)

-- | Draw a fixed-width month matrix beside the selected day's admitted facts.
draw :: AppContext -> Day -> Widget Name
draw context selectedDay =
  vBox
    [ hBox
        [ hLimit 32 (drawCalendar context selectedDay)
        , padLeft (Pad 1) (hLimit 46 (drawDayPane context selectedDay))
        ]
    , padTop (Pad 1) (drawLegend context)
    , str "[Arrows] Day   [t] Today   [r] Record   [1-7] Sections   [q] Quit"
    ]

drawCalendar :: AppContext -> Day -> Widget Name
drawCalendar context selectedDay =
  borderWithLabel (str (formatTime defaultTimeLocale "%B %Y" selectedDay))
    (padAll 1 (vBox (weekdayHeader : map drawWeek weeks)))
  where
    (year, month, _) = toGregorian selectedDay
    monthLength = gregorianMonthLength year month
    firstDay = fromGregorian year month 1
    (_, _, firstWeekday) = toWeekDate firstDay
    days = [fromGregorian year month day | day <- [1 .. monthLength]]
    leading = replicate (firstWeekday - 1) Nothing
    cells = leading ++ map Just days
    trailing = replicate ((7 - length cells `mod` 7) `mod` 7) Nothing
    weeks = chunksOf 7 (cells ++ trailing)
    weekdayHeader = hBox (map str [" Mo ", " Tu ", " We ", " Th ", " Fr ", " Sa ", " Su "])
    drawWeek = hBox . map drawCell
    drawCell Nothing = str "    "
    drawCell (Just day) =
      let (_, _, dayOfMonth) = toGregorian day
          marker = maybe ' ' calendarMarkerValue (markerForDay context day)
          dayLabel = T.justifyRight 2 ' ' (T.pack (show dayOfMonth))
          markerLabel = T.singleton marker <> " "
          dayNumber =
            if day == contextObservationDay context && day /= selectedDay
              then modifyDefAttr (`V.withStyle` V.dim) (txt dayLabel)
              else txt dayLabel
          cell = clickable (CalendarDay day)
            (hBox [dayNumber, txt markerLabel])
      in if day == selectedDay
          then withAttr (attrName "homeSelectedDay") cell
          else cell

chunksOf :: Int -> [value] -> [[value]]
chunksOf _ [] = []
chunksOf width values =
  let (chunk, rest) = splitAt width values
  in chunk : chunksOf width rest

-- | Calendar attention facts stay independent. A single fact gets its own
-- marker; overlaps get the configured multiple marker instead of a priority
-- winner. Actual existence remains visible in the selected-day pane.
markerForDay :: AppContext -> Day -> Maybe CalendarMarker
markerForDay context day =
  selectCalendarMarker markers
    (hasOpenPaymentPlan context day)
    (hasOpenIssueDue context day)
    (isCycleEnd context day)
  where
    markers = configuredMarkers context

configuredMarkers :: AppContext -> CalendarMarkers
configuredMarkers =
  presentationCalendarMarkers
    . reportConfigurationPresentation
    . householdStateReportConfig
    . contextHouseholdState

hasOpenPaymentPlan :: AppContext -> Day -> Bool
hasOpenPaymentPlan context day = not (null (plansOn context day))

hasOpenIssueDue :: AppContext -> Day -> Bool
hasOpenIssueDue context day = not (null (issuesDueOn context day))

isCycleEnd :: AppContext -> Day -> Bool
isCycleEnd context day = cycleEndDay context == Just day

actualsOn :: AppContext -> Day -> [Transaction]
actualsOn context day =
  homeActualTransactionsOn day
    (householdStateActualJournal (contextHouseholdState context))

plansOn :: AppContext -> Day -> [CommittedOutgoingPlan]
plansOn context day =
  maybe [] (homePlannedTransactionsOn day) (householdSurface context)

issuesDueOn :: AppContext -> Day -> [HouseholdIssue]
issuesDueOn context day =
  homeIssuesDueOn day (householdStateIssues (contextHouseholdState context))

cycleEndDay :: AppContext -> Maybe Day
cycleEndDay context = homeCycleEndDay <$> householdSurface context

householdSurface :: AppContext -> Maybe HouseholdReportSurface
householdSurface context = case contextHouseholdReportSurface context of
  Left _ -> Nothing
  Right surface -> Just surface

drawDayPane :: AppContext -> Day -> Widget Name
drawDayPane context selectedDay =
  borderWithLabel (str (formatTime defaultTimeLocale "%A, %Y-%m-%d" selectedDay))
    (vLimit 17
      (viewport HomeDayViewport Vertical
        (padAll 1
          (vBox
            ( actualSection
              ++ [str " "]
              ++ planSection
              ++ [str " "]
              ++ issueSection
              ++ [str " "]
              ++ cycleSection
              ++ projectionNote
            )))))
  where
    actualValues = actualsOn context selectedDay
    planValues = plansOn context selectedDay
    issueValues = issuesDueOn context selectedDay
    actualSection = str "Actual" : case actualValues of
      [] -> [str "  none recorded"]
      values -> concatMap renderActual values
    planSection = str "Plans" : case planValues of
      [] -> [str "  none"]
      values -> map renderPlan values
    issueSection = str "Issues due" : case issueValues of
      [] -> [str "  none"]
      values -> map renderIssue values
    cycleSection =
      [ str "Cycle"
      , if cycleEndDay context == Just selectedDay
          then str "  end day"
          else str "  none"
      ]
    projectionNote = case contextHouseholdReportSurface context of
      Left _ ->
        [ str " "
        , withAttr (attrName "warning")
            (str "Plan/cycle projection unavailable for this observation.")
        ]
      Right _ -> []

renderActual :: Transaction -> [Widget Name]
renderActual transaction =
  txt ("  " <> transactionDescription transaction)
    : map renderPosting (NonEmpty.toList (transactionPostings transaction))

renderPosting :: Posting -> Widget Name
renderPosting posting =
  txt ("    " <> accountName (postingAccount posting) <> "  "
    <> renderAmount (postingAmount posting))

renderPlan :: CommittedOutgoingPlan -> Widget Name
renderPlan plan =
  txt ("  " <> committedPlanMemo plan <> "  "
    <> renderAmount (positiveAmountValue (committedPlanAmount plan)))

renderIssue :: HouseholdIssue -> Widget Name
renderIssue issue =
  txt ("  " <> householdIssueText issue <> maybe "" (("  " <>) . renderAmount)
    (householdIssueAmount issue))

renderAmount :: Amount -> Text
renderAmount amount =
  renderQuantity (amountQuantity amount)
    <> " " <> commodityCode (amountCommodity amount)

drawLegend :: AppContext -> Widget Name
drawLegend context =
  txt
    ( markerText (calendarPlanDueMarker markers) <> " Plan due   "
      <> markerText (calendarIssueDueMarker markers) <> " Issue due   "
      <> markerText (calendarCycleEndMarker markers) <> " Cycle end   "
      <> markerText (calendarMultipleMarker markers) <> " Multiple"
    )
  where
    markers = configuredMarkers context
    markerText = T.singleton . calendarMarkerValue
