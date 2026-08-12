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

-- | Presentation-only glyphs for meaning already established by Household data.
--
-- Marker priority and the facts that cause a marker to appear are not
-- configurable here. This type changes only how those fixed semantic roles are
-- shown inside one calendar cell.
data CalendarMarkers = CalendarMarkers
  { calendarActualMarker :: CalendarMarker
  , calendarPlanMarker :: CalendarMarker
  , calendarIssueDueMarker :: CalendarMarker
  , calendarCycleEndMarker :: CalendarMarker
  } deriving (Eq, Show)

defaultCalendarMarkers :: CalendarMarkers
defaultCalendarMarkers = CalendarMarkers
  { calendarActualMarker = CalendarMarker '.'
  , calendarPlanMarker = CalendarMarker '+'
  , calendarIssueDueMarker = CalendarMarker '!'
  , calendarCycleEndMarker = CalendarMarker '|'
  }

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
