{-# LANGUAGE OverloadedStrings #-}

-- | Quiet calendar-first observation of one admitted Household.
--
-- This module owns no Household facts. It renders pure projections from the
-- shared editor workspace boundary onto a month matrix and selected-day pane.
module HKernel.Editor.TUI.Home
  ( HomeAction(..)
  , draw
  , handleLocalEvent
  , homeUsesStackedLayout
  ) where

import Brick
import Brick.Types (availWidthL, getContext)
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
import Lens.Micro ((^.))

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
import HKernel.Plan (planIdText)
import HKernel.Plan.Journal
  ( IdentifiedPlanTransaction
  , identifiedPlanId
  , identifiedPlanTransaction
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

-- | Keep the calendar and selected-day observation side by side when there is
-- room. Below 80 columns the same two observations stack instead of allowing
-- the right-hand pane to be cropped away.
draw :: AppContext -> Day -> Widget Name
draw context selectedDay =
  vBox
    [ responsiveWhen homeUsesStackedLayout compactLayout wideLayout
    , padTop (Pad 1) (drawLegend context)
    , strWrap "[Arrows] Day   [t] Today   [r] Record   [1-7] Sections   [q] Quit"
    ]
  where
    calendar = hLimit 32 (drawCalendar context selectedDay)
    dayPane = drawDayPane context selectedDay
    wideLayout = hBox
      [ calendar
      , padLeft (Pad 1) (hLimit 46 dayPane)
      ]
    compactLayout = vBox
      [ calendar
      , padTop (Pad 1) dayPane
      ]

-- | Pure width policy for the Home observation. Kept separate from Brick's
-- render context so representative terminal widths can be regression-tested.
homeUsesStackedLayout :: Int -> Bool
homeUsesStackedLayout width = width < 80

-- | Select a presentation using only Brick's rendering context. Terminal
-- dimensions remain presentation evidence and never enter Household state.
responsiveWhen :: (Int -> Bool) -> Widget name -> Widget name -> Widget name
responsiveWhen useCompact compact wide =
  Widget Greedy Fixed $ do
    context <- getContext
    render $
      if useCompact (context ^. availWidthL)
        then compact
        else wide

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
    (hasOpenPlan context day)
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

hasOpenPlan :: AppContext -> Day -> Bool
hasOpenPlan context day = case plansOn context day of
  Left _ -> False
  Right plans -> not (null plans)

hasOpenIssueDue :: AppContext -> Day -> Bool
hasOpenIssueDue context day = not (null (issuesDueOn context day))

isCycleEnd :: AppContext -> Day -> Bool
isCycleEnd context day = case cycleEndDay context of
  Left _ -> False
  Right endDay -> endDay == day

actualsOn :: AppContext -> Day -> [Transaction]
actualsOn context day =
  homeActualTransactionsOn day
    (householdStateActualJournal (contextHouseholdState context))

plansOn :: AppContext -> Day -> Either Text [IdentifiedPlanTransaction]
plansOn context day = case contextOpenPlanObservation context of
  Left errors -> Left (T.pack (show errors))
  Right plans -> Right (homePlannedTransactionsOn day plans)

issuesDueOn :: AppContext -> Day -> [HouseholdIssue]
issuesDueOn context day =
  homeIssuesDueOn day (householdStateIssues (contextHouseholdState context))

cycleEndDay :: AppContext -> Either Text Day
cycleEndDay context = case contextHouseholdCycleObservation context of
  Left errors -> Left (T.pack (show errors))
  Right observation -> Right (homeCycleEndDay observation)

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
            )))))
  where
    actualValues = actualsOn context selectedDay
    planValues = plansOn context selectedDay
    issueValues = issuesDueOn context selectedDay
    actualSection = str "Actual" : case actualValues of
      [] -> [str "  none recorded"]
      values -> concatMap renderActual values
    planSection = str "Plans" : case planValues of
      Left reason ->
        [ withAttr (attrName "warning")
            (txtWrap ("  unavailable for this observation: " <> reason))
        ]
      Right [] -> [str "  none"]
      Right values -> concatMap renderPlan values
    issueSection = str "Issues due" : case issueValues of
      [] -> [str "  none"]
      values -> map renderIssue values
    cycleSection = str "Cycle" : case cycleEndDay context of
      Left reason ->
        [ withAttr (attrName "warning")
            (txtWrap ("  unavailable for this observation: " <> reason))
        ]
      Right endDay
        | endDay == selectedDay -> [str "  end day"]
        | otherwise -> [str "  none"]

renderActual :: Transaction -> [Widget Name]
renderActual transaction =
  txtWrap ("  " <> transactionDescription transaction)
    : map renderPosting (NonEmpty.toList (transactionPostings transaction))

renderPosting :: Posting -> Widget Name
renderPosting posting =
  txtWrap ("    " <> accountName (postingAccount posting) <> "  "
    <> renderAmount (postingAmount posting))

renderPlan :: IdentifiedPlanTransaction -> [Widget Name]
renderPlan identified =
  txtWrap
      ("  " <> planIdText (identifiedPlanId identified)
        <> "  " <> transactionDescription transaction)
    : map renderPosting (NonEmpty.toList (transactionPostings transaction))
  where
    transaction = identifiedPlanTransaction identified

renderIssue :: HouseholdIssue -> Widget Name
renderIssue issue =
  txtWrap ("  " <> householdIssueText issue <> maybe "" (("  " <>) . renderAmount)
    (householdIssueAmount issue))

renderAmount :: Amount -> Text
renderAmount amount =
  renderQuantity (amountQuantity amount)
    <> " " <> commodityCode (amountCommodity amount)

drawLegend :: AppContext -> Widget Name
drawLegend context =
  txtWrap
    ( markerText (calendarPlanDueMarker markers) <> " Plan due   "
      <> markerText (calendarIssueDueMarker markers) <> " Issue due   "
      <> markerText (calendarCycleEndMarker markers) <> " Cycle end   "
      <> markerText (calendarMultipleMarker markers) <> " Multiple"
    )
  where
    markers = configuredMarkers context
    markerText = T.singleton . calendarMarkerValue
