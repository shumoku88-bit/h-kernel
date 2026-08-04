-- | Validated presentation coordinates shared by configuration and rendering.
module HKernel.Report.Presentation
  ( NegativeStyle(..)
  , NegativeToneColor(..)
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

-- | Terminal color choice for negative values in reports.
data NegativeToneColor
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
data PresentationConfig = PresentationConfig
  { presentationNegativeStyle :: NegativeStyle
  , presentationNegativeColor :: NegativeToneColor
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
  , presentationNegativeColor = RedColor
  , presentationDailyFlowDateColumns = defaultDateColumnCount
  }

