{-# LANGUAGE OverloadedStrings #-}

-- | Quiet calendar-first observation of one admitted Household.
--
-- This module owns no Household facts. It renders pure projections from the
-- shared editor workspace boundary onto a month matrix and selected-day pane.
module HKernel.Editor.TUI.Home
  ( CalendarMarkerObservation(..)
  , HomeAction(..)
  , calendarMarkerObservation
  , draw
  , drawCalendarWithFocus
  , drawDayPaneFull
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
  ( HomeActualObservation(..)
  , HomeIssueObservation(..)
  , homeActualObservationOn
  , homeCycleEndDay
  , homeIssueObservationOn
  , homePlannedTransactionsOn
  , workspaceOpenPlanObservationAt
  )
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , Name(..)
  , contextHouseholdCycleObservation
  , contextHouseholdState
  )
import HKernel.Editor.TUI.Scroll qualified as Scroll
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
  | HomeObserveChange Day
  deriving (Eq, Show)

-- | Calendar summary cells must distinguish a fully observed empty day from a
-- day whose Plan, Issue, or Cycle observation is unavailable. The calendar is
-- intentionally conservative: one unavailable input makes the summary marker
-- unavailable rather than pretending the missing fact is absent.
data CalendarMarkerObservation
  = CalendarMarkerAvailable (Maybe CalendarMarker)
  | CalendarMarkerUnavailable
  deriving (Eq, Show)

calendarMarkerObservation
  :: CalendarMarkers
  -> Either planError Bool
  -> Either issueError Bool
  -> Either cycleError Bool
  -> CalendarMarkerObservation
calendarMarkerObservation markers planDue issueDue cycleEnd =
  case (planDue, issueDue, cycleEnd) of
    (Right hasPlan, Right hasIssue, Right isEnd) ->
      CalendarMarkerAvailable
        (selectCalendarMarker markers hasPlan hasIssue isEnd)
    _ -> CalendarMarkerUnavailable

-- | Handle only interaction local to the calendar surface. Application-shell
-- navigation remains in Main.
handleLocalEvent
  :: Day
  -> BrickEvent Name AppEvent
  -> EventM Name AppContext HomeAction
handleLocalEvent selectedDay event =
  case Scroll.viewportWheelHandler HomeDayViewport Scroll.VerticalOnly event of
    Just scroll -> scroll >> pure HomeMaintain
    Nothing -> handleNonWheel event
  where
    handleNonWheel currentEvent = case currentEvent of
      MouseDown (CalendarDay day) V.BLeft _ _ -> selectDay day
      MouseDown (HomeChangeFrom day) V.BLeft _ _ -> pure (HomeObserveChange day)
      VtyEvent (V.EvKey V.KLeft []) -> selectDay (addDays (-1) selectedDay)
      VtyEvent (V.EvKey V.KRight []) -> selectDay (addDays 1 selectedDay)
      VtyEvent (V.EvKey V.KUp []) -> selectDay (addDays (-7) selectedDay)
      VtyEvent (V.EvKey V.KDown []) -> selectDay (addDays 7 selectedDay)
      VtyEvent (V.EvKey (V.KChar 'h') []) -> selectDay (addDays (-1) selectedDay)
      VtyEvent (V.EvKey (V.KChar 'H') []) -> selectDay (addDays (-1) selectedDay)
      VtyEvent (V.EvKey (V.KChar 'l') []) -> selectDay (addDays 1 selectedDay)
      VtyEvent (V.EvKey (V.KChar 'L') []) -> selectDay (addDays 1 selectedDay)
      VtyEvent (V.EvKey (V.KChar 'k') []) -> selectDay (addDays (-7) selectedDay)
      VtyEvent (V.EvKey (V.KChar 'K') []) -> selectDay (addDays (-7) selectedDay)
      VtyEvent (V.EvKey (V.KChar 'j') []) -> selectDay (addDays 7 selectedDay)
      VtyEvent (V.EvKey (V.KChar 'J') []) -> selectDay (addDays 7 selectedDay)
      VtyEvent (V.EvKey (V.KChar 't') []) -> today
      VtyEvent (V.EvKey (V.KChar 'T') []) -> today
      VtyEvent (V.EvKey (V.KChar 'r') []) -> pure (HomeRecord selectedDay)
      VtyEvent (V.EvKey (V.KChar 'R') []) -> pure (HomeRecord selectedDay)
      VtyEvent (V.EvKey V.KEnter []) -> pure (HomeObserveChange selectedDay)
      _ -> pure HomeMaintain
    selectDay day = do
      vScrollToBeginning (viewportScroll HomeDayViewport)
      pure (HomeSelectDay day)
    today = do
      context <- get
      selectDay (contextObservationDay context)

-- | Keep the calendar and selected-day observation side by side when there is
-- room. The roomier five-column day cells make the combined surface 86 columns
-- wide, so widths below 87 stack instead of cropping the right-hand pane.
draw :: AppContext -> Day -> Widget Name
draw context selectedDay =
  vBox
    [ responsiveWhen homeUsesStackedLayout compactLayout wideLayout
    , padTop (Pad 1) (drawLegend context)
    , padTop (Pad 1)
        (clickable (HomeChangeFrom selectedDay)
          (strWrap "[Enter/click] Envelope change from selected day to observation"))
    , strWrap "[Arrows] Day   [t] Today   [r] Record   [Tab] Sections   [q] Quit"
    ]
  where
    calendar = hLimit 39 (drawCalendarWithFocus False context selectedDay)
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
homeUsesStackedLayout width = width < 87

-- | Select a presentation using only Brick's current render context. Terminal
-- dimensions remain presentation evidence and never enter Household state.
responsiveWhen :: (Int -> Bool) -> Widget name -> Widget name -> Widget name
responsiveWhen useCompact compact wide =
  Widget Greedy Fixed $ do
    context <- getContext
    render $
      if useCompact (context ^. availWidthL)
        then compact
        else wide

-- | Draw the real Household calendar. Focus decoration is presentation-only;
-- the selected day and markers keep their existing admitted semantics.
drawCalendarWithFocus :: Bool -> AppContext -> Day -> Widget Name
drawCalendarWithFocus focused context selectedDay =
  borderWithLabel monthLabel
    (padAll 1 (vBox (weekdayHeader : map drawWeek weeks)))
  where
    rawMonthLabel = T.pack (formatTime defaultTimeLocale "%B %Y" selectedDay)
    monthLabel
      | focused = withAttr (attrName "shellFocus") (txt ("[" <> rawMonthLabel <> "]"))
      | otherwise = txt rawMonthLabel
    (year, month, _) = toGregorian selectedDay
    monthLength = gregorianMonthLength year month
    firstDay = fromGregorian year month 1
    (_, _, firstWeekday) = toWeekDate firstDay
    days = [fromGregorian year month day | day <- [1 .. monthLength]]
    leading = replicate (firstWeekday - 1) Nothing
    cells = leading ++ map Just days
    trailing = replicate ((7 - length cells `mod` 7) `mod` 7) Nothing
    weeks = chunksOf 7 (cells ++ trailing)
    weekdayHeader = hBox (map str [" Mo  ", " Tu  ", " We  ", " Th  ", " Fr  ", " Sa  ", " Su  "])
    drawWeek = hBox . map drawCell
    drawCell Nothing = str "     "
    drawCell (Just day) =
      let (_, _, dayOfMonth) = toGregorian day
          dayLabel = T.justifyRight 2 ' ' (T.pack (show dayOfMonth))
          dayNumber =
            if day == contextObservationDay context && day /= selectedDay
              then modifyDefAttr (`V.withStyle` V.dim) (txt dayLabel)
              else txt dayLabel
          markerWidget = case markerObservationForDay context day of
            CalendarMarkerAvailable Nothing -> txt "   "
            CalendarMarkerAvailable (Just marker) ->
              txt (" " <> T.singleton (calendarMarkerValue marker) <> " ")
            CalendarMarkerUnavailable ->
              withAttr (attrName "warning") (txt " ? ")
          cell = clickable (CalendarDay day)
            (hBox [dayNumber, markerWidget])
      in if day == selectedDay
          then withAttr (attrName "homeSelectedDay") cell
          else cell

chunksOf :: Int -> [value] -> [[value]]
chunksOf _ [] = []
chunksOf width values =
  let (chunk, rest) = splitAt width values
  in chunk : chunksOf width rest

markerObservationForDay :: AppContext -> Day -> CalendarMarkerObservation
markerObservationForDay context day =
  calendarMarkerObservation markers planFact issueFact cycleFact
  where
    markers = configuredMarkers context
    planFact = not . null <$> plansOn context day
    issueFact = case issuesDueOn context day of
      HomeIssueUnavailable _ -> Left ()
      HomeIssueAvailable issues -> Right (not (null issues))
    cycleFact = (== day) <$> cycleEndDay context

configuredMarkers :: AppContext -> CalendarMarkers
configuredMarkers =
  presentationCalendarMarkers
    . reportConfigurationPresentation
    . householdStateReportConfig
    . contextHouseholdState

actualsOn :: AppContext -> Day -> HomeActualObservation
actualsOn context day =
  homeActualObservationOn
    (contextObservationDay context)
    day
    (householdStateActualJournal (contextHouseholdState context))

plansOn :: AppContext -> Day -> Either Text [IdentifiedPlanTransaction]
plansOn context day = case workspaceOpenPlanObservationAt
    (contextObservationDay context)
    (householdStatePlanJournal state)
    (householdStateActualJournal state) of
  Left errors -> Left (T.pack (show errors))
  Right plans -> Right (homePlannedTransactionsOn day plans)
  where
    state = contextHouseholdState context

issuesDueOn :: AppContext -> Day -> HomeIssueObservation
issuesDueOn context day =
  homeIssueObservationOn
    (contextObservationDay context)
    day
    (householdStateIssues (contextHouseholdState context))

cycleEndDay :: AppContext -> Either Text Day
cycleEndDay context = case contextHouseholdCycleObservation context of
  Left errors -> Left (T.pack (show errors))
  Right observation -> Right (homeCycleEndDay observation)

drawDayPane :: AppContext -> Day -> Widget Name
drawDayPane context selectedDay =
  borderWithLabel dayLabel
    (vLimit 17 (drawDayViewport context selectedDay))
  where
    dayLabel = str (formatTime defaultTimeLocale "%A, %Y-%m-%d" selectedDay)

-- | Full-height variant for the persistent application shell. It renders the
-- same selected-day projection as Home and retains the Home change affordance;
-- only the presentation allocation is different.
drawDayPaneFull :: AppContext -> Day -> Widget Name
drawDayPaneFull context selectedDay =
  vBox
    [ borderWithLabel dayLabel
        (padBottom Max (drawDayViewport context selectedDay))
    , padTop (Pad 1)
        (clickable (HomeChangeFrom selectedDay)
          (strWrap "[Enter/click] Envelope change from selected day to observation"))
    ]
  where
    dayLabel = str (formatTime defaultTimeLocale "%A, %Y-%m-%d" selectedDay)

drawDayViewport :: AppContext -> Day -> Widget Name
drawDayViewport context selectedDay =
  viewport HomeDayViewport Vertical
    (padAll 1
      (vBox
        ( actualSection
          ++ [str " "]
          ++ planSection
          ++ [str " "]
          ++ issueSection
          ++ [str " "]
          ++ cycleSection
        )))
  where
    actualValues = actualsOn context selectedDay
    planValues = plansOn context selectedDay
    issueValues = issuesDueOn context selectedDay
    actualSection = str "Actual" : case actualValues of
      HomeActualUnavailable ->
        [ withAttr (attrName "warning")
            (strWrap "  unavailable beyond this observation horizon")
        ]
      HomeActualAvailable [] -> [str "  none recorded"]
      HomeActualAvailable values -> concatMap renderActual values
    planSection = str "Plans" : case planValues of
      Left reason ->
        [ withAttr (attrName "warning")
            (txtWrap ("  unavailable for this observation: " <> reason))
        ]
      Right [] -> [str "  none"]
      Right values -> concatMap renderPlan values
    issueSection = str "Issues due" : case issueValues of
      HomeIssueUnavailable errors ->
        [ withAttr (attrName "warning")
            (txtWrap ("  unavailable for this observation: " <> T.pack (show errors)))
        ]
      HomeIssueAvailable [] -> [str "  none"]
      HomeIssueAvailable values -> map renderIssue values
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
      <> markerText (calendarMultipleMarker markers) <> " Multiple   ? Unavailable"
    )
  where
    markers = configuredMarkers context
    markerText = T.singleton . calendarMarkerValue
