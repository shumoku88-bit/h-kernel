-- | Validated presentation coordinates shared by configuration and rendering.
module HKernel.Report.Presentation
  ( NegativeStyle(..)
  , PresentationColor(..)
  , CalendarMarker
  , CalendarMarkerError(..)
  , mkCalendarMarker
  , calendarMarkerValue
  , CalendarMarkers(..)
  , defaultCalendarMarkers
  , selectCalendarMarker
  , PresentationConfig(..)
  , defaultPresentationConfig
  , DateColumnCount
  , DateColumnCountError(..)
  , mkDateColumnCount
  , dateColumnCountValue
  , defaultDateColumnCount
  ) where

import Data.Char (isAscii, isPrint, isSpace)
import Data.Text (Text)
import qualified Data.Text as T

-- | Terminal notation for a negative quantity. The domain value remains signed.
data NegativeStyle
  = AccountingParentheses
  | LeadingMinus
  deriving (Eq, Show)

-- | Validated terminal color available to semantic report presentation roles.
--
-- The role lives in 'PresentationConfig'; this value only states which terminal
-- color is selected for that role.
data PresentationColor
  = RedColor
  | BrightRedColor
  | GreenColor
  | YellowColor
  | BlueColor
  | MagentaColor
  | CyanColor
  | WhiteColor
  deriving (Eq, Show)

-- | One fixed-width ASCII marker for the Household calendar matrix.
--
-- Calendar cells reserve exactly one terminal column for this coordinate. The
-- validated value therefore excludes whitespace, control characters, Unicode,
-- and multi-character strings without making the core presentation model depend
-- on Brick or Vty terminal-width logic.
newtype CalendarMarker = CalendarMarker Char
  deriving (Eq, Show)

data CalendarMarkerError
  = CalendarMarkerMustBeSingleAsciiGraphic Text
  deriving (Eq, Show)

mkCalendarMarker :: Text -> Either CalendarMarkerError CalendarMarker
mkCalendarMarker value = case T.unpack value of
  [marker]
    | isAscii marker && isPrint marker && not (isSpace marker) ->
        Right (CalendarMarker marker)
  _ -> Left (CalendarMarkerMustBeSingleAsciiGraphic value)

calendarMarkerValue :: CalendarMarker -> Char
calendarMarkerValue (CalendarMarker marker) = marker

-- | Presentation-only glyphs for independent calendar attention facts.
--
-- Actual existence is deliberately not a marker role. It remains observable in
-- the selected-day detail. Plan due, Issue due, and cycle end remain independent
-- facts; when more than one is true, the multiple marker preserves that overlap
-- instead of hiding facts behind a priority rule.
data CalendarMarkers = CalendarMarkers
  { calendarPlanDueMarker :: CalendarMarker
  , calendarIssueDueMarker :: CalendarMarker
  , calendarCycleEndMarker :: CalendarMarker
  , calendarMultipleMarker :: CalendarMarker
  } deriving (Eq, Show)

defaultCalendarMarkers :: CalendarMarkers
defaultCalendarMarkers = CalendarMarkers
  { calendarPlanDueMarker = CalendarMarker '$'
  , calendarIssueDueMarker = CalendarMarker '!'
  , calendarCycleEndMarker = CalendarMarker '|'
  , calendarMultipleMarker = CalendarMarker '+'
  }

-- | Choose presentation for three already-established, independent day facts.
--
-- The arguments are Plan due, Issue due, and cycle end respectively. No fact is
-- semantically preferred over another; any overlap is represented explicitly.
selectCalendarMarker
  :: CalendarMarkers
  -> Bool
  -> Bool
  -> Bool
  -> Maybe CalendarMarker
selectCalendarMarker markers planDue issueDue cycleEnd =
  case (planDue, issueDue, cycleEnd) of
    (False, False, False) -> Nothing
    (True,  False, False) -> Just (calendarPlanDueMarker markers)
    (False, True,  False) -> Just (calendarIssueDueMarker markers)
    (False, False, True)  -> Just (calendarCycleEndMarker markers)
    _ -> Just (calendarMultipleMarker markers)

-- | Validated presentation policy shared by reports and Household UI surfaces.
--
-- Hierarchy colors, amount tones, calendar markers, and layout coordinates are
-- explicit here. Success/failure status colors and dim/bold emphasis remain
-- renderer semantics rather than being conflated with amount sign, report
-- hierarchy, or Household calendar meaning.
data PresentationConfig = PresentationConfig
  { presentationNegativeStyle :: NegativeStyle
  , presentationHeadingColor :: PresentationColor
  , presentationSectionColor :: PresentationColor
  , presentationPositiveAmountColor :: PresentationColor
  , presentationNegativeAmountColor :: PresentationColor
  , presentationCalendarMarkers :: CalendarMarkers
  , presentationDailyFlowDateColumns :: DateColumnCount
  } deriving (Eq, Show)

newtype DateColumnCount = DateColumnCount Int
  deriving (Eq, Show)

data DateColumnCountError
  = NonPositiveDateColumnCount Int
  deriving (Eq, Show)

mkDateColumnCount :: Int -> Either DateColumnCountError DateColumnCount
mkDateColumnCount value
  | value > 0 = Right (DateColumnCount value)
  | otherwise = Left (NonPositiveDateColumnCount value)

dateColumnCountValue :: DateColumnCount -> Int
dateColumnCountValue (DateColumnCount value) = value

defaultDateColumnCount :: DateColumnCount
defaultDateColumnCount = DateColumnCount 14

defaultPresentationConfig :: PresentationConfig
defaultPresentationConfig = PresentationConfig
  { presentationNegativeStyle = AccountingParentheses
  , presentationHeadingColor = CyanColor
  , presentationSectionColor = YellowColor
  , presentationPositiveAmountColor = GreenColor
  , presentationNegativeAmountColor = RedColor
  , presentationCalendarMarkers = defaultCalendarMarkers
  , presentationDailyFlowDateColumns = defaultDateColumnCount
  }
