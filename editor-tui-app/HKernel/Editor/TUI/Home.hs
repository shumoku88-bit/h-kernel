{-# LANGUAGE OverloadedStrings #-}

-- | Quiet calendar-first observation of one admitted Household.
--
-- This module owns no Household facts. It projects already admitted Actual,
-- Plan, Issue, cycle, and presentation values onto a month matrix and one
-- selected-day pane.
module HKernel.Editor.TUI.Home
  ( draw
  ) where

import Brick
import Brick.Widgets.Border (borderWithLabel)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Calendar
  ( Day
  , fromGregorian
  , gregorianMonthLength
  , toGregorian
  )
import Data.Time.Calendar.WeekDate (toWeekDate)
import Data.Time.Format (defaultTimeLocale, formatTime)

import HKernel.Account (accountName)
import HKernel.Actual.Journal
  ( actualJournalTransactionEntries
  , actualTransactionEntryTransaction
  )
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , Name(..)
  , contextHouseholdState
  )
import HKernel.Household.Application (HouseholdState(..))
import HKernel.Household.Report
  ( HouseholdReportSurface(..)
  )
import HKernel.HouseholdIssue
  ( HouseholdIssue
  , IssueDue(..)
  , IssueStatus(..)
  , householdIssueAmount
  , householdIssueDue
  , householdIssueStatus
  , householdIssueText
  )
import HKernel.Ledger
  ( Posting
  , Transaction
  , postingAccount
  , postingAmount
  , transactionDate
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
import HKernel.Period (periodEndExclusive)
import HKernel.Plan
  ( CommittedOutgoingPlan
  , committedPlanAmount
  , committedPlanDate
  , committedPlanMemo
  , positiveAmountValue
  )
import HKernel.Report.Config (reportConfigurationPresentation)
import HKernel.Report.CycleAccounts (currentCycleAccountsPeriod)
import HKernel.Report.Presentation
  ( CalendarMarker
  , CalendarMarkers(..)
  , calendarMarkerValue
  , presentationCalendarMarkers
  )

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
          label = T.justifyRight 2 ' ' (T.pack (show dayOfMonth))
            <> T.singleton marker <> " "
          cell = clickable (CalendarDay day) (txt label)
      in if day == selectedDay
          then withAttr (attrName "homeSelectedDay") cell
          else cell

chunksOf :: Int -> [value] -> [[value]]
chunksOf _ [] = []
chunksOf width values =
  let (chunk, rest) = splitAt width values
  in chunk : chunksOf width rest

-- | Exactly one marker is chosen so every calendar cell stays four columns.
-- Priority is semantic and intentionally not configurable.
markerForDay :: AppContext -> Day -> Maybe CalendarMarker
markerForDay context day
  | hasOpenIssueDue context day = Just (calendarIssueDueMarker markers)
  | isCycleBoundary context day = Just (calendarCycleEndMarker markers)
  | hasOpenPaymentPlan context day = Just (calendarPlanMarker markers)
  | hasActual context day = Just (calendarActualMarker markers)
  | otherwise = Nothing
  where
    markers = configuredMarkers context

configuredMarkers :: AppContext -> CalendarMarkers
configuredMarkers =
  presentationCalendarMarkers
    . reportConfigurationPresentation
    . householdStateReportConfig
    . contextHouseholdState

hasActual :: AppContext -> Day -> Bool
hasActual context day = not (null (actualsOn context day))

hasOpenPaymentPlan :: AppContext -> Day -> Bool
hasOpenPaymentPlan context day = not (null (plansOn context day))

hasOpenIssueDue :: AppContext -> Day -> Bool
hasOpenIssueDue context day = not (null (issuesDueOn context day))

isCycleBoundary :: AppContext -> Day -> Bool
isCycleBoundary context day = cycleBoundary context == Just day

actualsOn :: AppContext -> Day -> [Transaction]
actualsOn context day =
  [ transaction
  | entry <- actualJournalTransactionEntries
      (householdStateActualJournal (contextHouseholdState context))
  , let transaction = actualTransactionEntryTransaction entry
  , transactionDate transaction == day
  ]

plansOn :: AppContext -> Day -> [CommittedOutgoingPlan]
plansOn context day =
  [ plan
  | plan <- maybe [] householdPlannedTransactions (householdSurface context)
  , committedPlanDate plan == day
  ]

issuesDueOn :: AppContext -> Day -> [HouseholdIssue]
issuesDueOn context day =
  [ issue
  | issue <- householdStateIssues (contextHouseholdState context)
  , householdIssueStatus issue == Open
  , householdIssueDue issue == DueOn day
  ]

cycleBoundary :: AppContext -> Maybe Day
cycleBoundary context = do
  surface <- householdSurface context
  pure
    (periodEndExclusive
      (currentCycleAccountsPeriod (householdCurrentCycleAccounts surface)))

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
            ))))
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
      , if cycleBoundary context == Just selectedDay
          then str "  boundary"
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
    ( markerText (calendarActualMarker markers) <> " Actual   "
      <> markerText (calendarPlanMarker markers) <> " Plan   "
      <> markerText (calendarIssueDueMarker markers) <> " Issue due   "
      <> markerText (calendarCycleEndMarker markers) <> " Cycle boundary"
    )
  where
    markers = configuredMarkers context
    markerText = T.singleton . calendarMarkerValue
