-- | Validated presentation coordinates shared by configuration and rendering.
module HKernel.Report.Presentation
  ( NegativeStyle(..)
  , PresentationColor(..)
  , PresentationConfig(..)
  , defaultPresentationConfig
  , DateColumnCount
  , DateColumnCountError(..)
  , mkDateColumnCount
  , dateColumnCountValue
  , defaultDateColumnCount
  ) where

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

-- | Validated presentation policy shared by ReportBook and standalone reports.
--
-- Hierarchy colors, amount tones, and layout coordinates are explicit here.
-- Success/failure status colors and dim/bold emphasis remain renderer semantics
-- rather than being conflated with amount sign or report hierarchy.
data PresentationConfig = PresentationConfig
  { presentationNegativeStyle :: NegativeStyle
  , presentationHeadingColor :: PresentationColor
  , presentationSectionColor :: PresentationColor
  , presentationPositiveAmountColor :: PresentationColor
  , presentationNegativeAmountColor :: PresentationColor
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
  , presentationDailyFlowDateColumns = defaultDateColumnCount
  }
