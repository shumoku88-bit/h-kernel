{-# LANGUAGE OverloadedStrings #-}

-- | TOML decoding and canonical rendering for report period and presentation plans.
--
-- TOML syntax is converted immediately into typed domain values. The report
-- engine never depends on TOML values, and canonical publication is derived
-- from the validated configuration rather than preserving incidental formatting.
module HKernel.Report.Config
  ( ReportConfiguration(..)
  , parseReportConfiguration
  , parseReportConfig
  , renderReportConfiguration
  , renderReportConfigErrors
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, formatTime, parseTimeM)
import HKernel.Report.Plan
import HKernel.Report.Presentation
import HKernel.Report.RecentTransactions
  ( RecentCount
  , mkRecentCount
  , recentCountValue
  )
import Toml (decode)
import Toml.Schema
  ( FromValue(..)
  , Result(..)
  , optKey
  , parseTableFromValue
  , reqKey
  )

data ReportConfiguration = ReportConfiguration
  { reportConfigurationPlan :: ReportPlan
  , reportConfigurationPresentation :: PresentationConfig
  } deriving (Eq, Show)

data RawConfig = RawConfig (Maybe RawPresentation) RawReports

data RawPresentation = RawPresentation (Maybe RawHierarchy) (Maybe RawAmounts)

data RawHierarchy = RawHierarchy (Maybe Text) (Maybe Text)

data RawAmounts = RawAmounts Text (Maybe Text) (Maybe Text)

data RawReports = RawReports
  RawAsOf
  RawAsOf
  RawRange
  RawDailyFlow
  RawRange
  RawRecent

data RawAsOf = RawAsOf Text

data RawRange = RawRange Text Text

data RawDailyFlow = RawDailyFlow Text Text (Maybe Integer)

data RawRecent = RawRecent Text Integer

instance FromValue RawConfig where
  fromValue = parseTableFromValue
    (RawConfig <$> optKey "presentation" <*> reqKey "reports")

instance FromValue RawPresentation where
  fromValue = parseTableFromValue
    (RawPresentation
      <$> optKey "hierarchy"
      <*> optKey "amounts")

instance FromValue RawHierarchy where
  fromValue = parseTableFromValue
    (RawHierarchy
      <$> optKey "heading-color"
      <*> optKey "section-color")

instance FromValue RawAmounts where
  fromValue = parseTableFromValue
    (RawAmounts
      <$> reqKey "negative-style"
      <*> optKey "positive-color"
      <*> optKey "negative-color")

instance FromValue RawReports where
  fromValue = parseTableFromValue
    (RawReports
      <$> reqKey "trial-balance"
      <*> reqKey "balance-sheet"
      <*> reqKey "profit-and-loss"
      <*> reqKey "daily-flow"
      <*> reqKey "monthly-accounts"
      <*> reqKey "recent-transactions")

instance FromValue RawAsOf where
  fromValue = parseTableFromValue (RawAsOf <$> reqKey "as-of")

instance FromValue RawRange where
  fromValue = parseTableFromValue
    (RawRange <$> reqKey "from" <*> reqKey "through")

instance FromValue RawDailyFlow where
  fromValue = parseTableFromValue
    (RawDailyFlow
      <$> reqKey "from"
      <*> reqKey "through"
      <*> optKey "max-date-columns")

instance FromValue RawRecent where
  fromValue = parseTableFromValue
    (RawRecent <$> reqKey "through" <*> reqKey "count")

parseReportConfiguration :: Text -> Either [Text] ReportConfiguration
parseReportConfiguration input = case (decode input :: Result String RawConfig) of
  Failure errors -> Left (map T.pack errors)
  Success warnings raw
    | null warnings -> rawConfigToConfiguration raw
    | otherwise -> Left (map T.pack warnings)

-- | Decode only the symbolic period plan for callers that do not render.
parseReportConfig :: Text -> Either [Text] ReportPlan
parseReportConfig = fmap reportConfigurationPlan . parseReportConfiguration

-- | Render one admitted report configuration as deterministic canonical TOML.
--
-- The serializer owns only query defaults and presentation. It never embeds
-- canonical source filenames, Account classification, Envelope membership, or
-- other Household policy coordinates.
renderReportConfiguration :: ReportConfiguration -> Text
renderReportConfiguration configuration = T.unlines
  [ "[presentation.hierarchy]"
  , "heading-color = " <> quoted (renderPresentationColor
      (presentationHeadingColor presentation))
  , "section-color = " <> quoted (renderPresentationColor
      (presentationSectionColor presentation))
  , ""
  , "[presentation.amounts]"
  , "negative-style = " <> quoted (renderNegativeStyle
      (presentationNegativeStyle presentation))
  , "positive-color = " <> quoted (renderPresentationColor
      (presentationPositiveAmountColor presentation))
  , "negative-color = " <> quoted (renderPresentationColor
      (presentationNegativeAmountColor presentation))
  , ""
  , "[reports.trial-balance]"
  , "as-of = " <> quoted (renderAsOf (trialBalanceSpec plan))
  , ""
  , "[reports.balance-sheet]"
  , "as-of = " <> quoted (renderAsOf (balanceSheetSpec plan))
  , ""
  , "[reports.profit-and-loss]"
  , renderRangeLine "from" (profitAndLossSpec plan)
  , renderRangeThroughLine (profitAndLossSpec plan)
  , ""
  , "[reports.daily-flow]"
  , renderRangeLine "from" (dailyFlowSpec plan)
  , renderRangeThroughLine (dailyFlowSpec plan)
  , "max-date-columns = " <> T.pack
      (show (dateColumnCountValue
        (presentationDailyFlowDateColumns presentation)))
  , ""
  , "[reports.monthly-accounts]"
  , renderRangeLine "from" (monthlyAccountsSpec plan)
  , renderRangeThroughLine (monthlyAccountsSpec plan)
  , ""
  , "[reports.recent-transactions]"
  , "through = " <> quoted (renderEndBoundary
      (recentSpecThrough (recentTransactionsSpec plan)))
  , "count = " <> T.pack
      (show (recentCountValue
        (recentSpecCount (recentTransactionsSpec plan))))
  ]
  where
    plan = reportConfigurationPlan configuration
    presentation = reportConfigurationPresentation configuration

renderNegativeStyle :: NegativeStyle -> Text
renderNegativeStyle AccountingParentheses = "parentheses"
renderNegativeStyle LeadingMinus = "minus"

renderPresentationColor :: PresentationColor -> Text
renderPresentationColor RedColor = "red"
renderPresentationColor BrightRedColor = "bright-red"
renderPresentationColor GreenColor = "green"
renderPresentationColor YellowColor = "yellow"
renderPresentationColor BlueColor = "blue"
renderPresentationColor MagentaColor = "magenta"
renderPresentationColor CyanColor = "cyan"
renderPresentationColor WhiteColor = "white"

renderAsOf :: AsOfSpec -> Text
renderAsOf (AsOf reference) = renderDateReference reference

renderDateReference :: DateReference -> Text
renderDateReference Latest = "latest"
renderDateReference (ExactDate day) = renderDay day

renderRangeLine :: Text -> RangeSpec -> Text
renderRangeLine key (RangeSpec start _) =
  key <> " = " <> quoted (renderStartBoundary start)

renderRangeThroughLine :: RangeSpec -> Text
renderRangeThroughLine (RangeSpec _ end) =
  "through = " <> quoted (renderEndBoundary end)

renderStartBoundary :: StartBoundary -> Text
renderStartBoundary FromBeginning = "beginning"
renderStartBoundary (FromDate day) = renderDay day

renderEndBoundary :: EndBoundary -> Text
renderEndBoundary ThroughLatest = "latest"
renderEndBoundary (ThroughDate day) = renderDay day

renderDay :: Day -> Text
renderDay = T.pack . formatTime defaultTimeLocale "%F"

quoted :: Text -> Text
quoted value = "\"" <> value <> "\""

renderReportConfigErrors :: [Text] -> Text
renderReportConfigErrors = T.unlines . map ("  " <>)

rawConfigToConfiguration :: RawConfig -> Either [Text] ReportConfiguration
rawConfigToConfiguration (RawConfig rawPresentation reports) = case reports of
  RawReports trial balance profit daily monthly recent -> do
    negativeStyle <- parseNegativeStyle rawPresentation
    headingColor <- parseHierarchyColor
      "presentation.hierarchy.heading-color"
      CyanColor
      rawPresentation
      hierarchyHeadingColor
    sectionColor <- parseHierarchyColor
      "presentation.hierarchy.section-color"
      YellowColor
      rawPresentation
      hierarchySectionColor
    positiveAmountColor <- parseAmountColor
      "presentation.amounts.positive-color"
      GreenColor
      rawPresentation
      amountPositiveColor
    negativeAmountColor <- parseAmountColor
      "presentation.amounts.negative-color"
      RedColor
      rawPresentation
      amountNegativeColor
    trialSpec <- parseAsOf "reports.trial-balance.as-of" trial
    balanceSpec <- parseAsOf "reports.balance-sheet.as-of" balance
    profitSpec <- parseRange "reports.profit-and-loss" profit
    (dailySpec', dateColumns) <- parseDailyFlow daily
    monthlySpec <- parseRange "reports.monthly-accounts" monthly
    recentSpec' <- parseRecent recent
    pure ReportConfiguration
      { reportConfigurationPlan = ReportPlan
          { trialBalanceSpec = trialSpec
          , balanceSheetSpec = balanceSpec
          , profitAndLossSpec = profitSpec
          , dailyFlowSpec = dailySpec'
          , monthlyAccountsSpec = monthlySpec
          , recentTransactionsSpec = recentSpec'
          }
      , reportConfigurationPresentation = PresentationConfig
          { presentationNegativeStyle = negativeStyle
          , presentationHeadingColor = headingColor
          , presentationSectionColor = sectionColor
          , presentationPositiveAmountColor = positiveAmountColor
          , presentationNegativeAmountColor = negativeAmountColor
          , presentationDailyFlowDateColumns = dateColumns
          }
      }

parseNegativeStyle :: Maybe RawPresentation -> Either [Text] NegativeStyle
parseNegativeStyle Nothing = Right AccountingParentheses
parseNegativeStyle (Just (RawPresentation _ Nothing)) = Right AccountingParentheses
parseNegativeStyle (Just (RawPresentation _ (Just (RawAmounts value _ _)))) = case value of
  "parentheses" -> Right AccountingParentheses
  "minus" -> Right LeadingMinus
  _ -> Left
    [ "presentation.amounts.negative-style: expected parentheses or minus; got ‘"
        <> value <> "’"
    ]

parseHierarchyColor
  :: Text
  -> PresentationColor
  -> Maybe RawPresentation
  -> (RawHierarchy -> Maybe Text)
  -> Either [Text] PresentationColor
parseHierarchyColor _ fallback Nothing _ = Right fallback
parseHierarchyColor _ fallback (Just (RawPresentation Nothing _)) _ = Right fallback
parseHierarchyColor path fallback (Just (RawPresentation (Just hierarchy) _)) select =
  parseOptionalPresentationColor path fallback (select hierarchy)

parseAmountColor
  :: Text
  -> PresentationColor
  -> Maybe RawPresentation
  -> (RawAmounts -> Maybe Text)
  -> Either [Text] PresentationColor
parseAmountColor _ fallback Nothing _ = Right fallback
parseAmountColor _ fallback (Just (RawPresentation _ Nothing)) _ = Right fallback
parseAmountColor path fallback (Just (RawPresentation _ (Just amounts))) select =
  parseOptionalPresentationColor path fallback (select amounts)

hierarchyHeadingColor :: RawHierarchy -> Maybe Text
hierarchyHeadingColor (RawHierarchy value _) = value

hierarchySectionColor :: RawHierarchy -> Maybe Text
hierarchySectionColor (RawHierarchy _ value) = value

amountPositiveColor :: RawAmounts -> Maybe Text
amountPositiveColor (RawAmounts _ value _) = value

amountNegativeColor :: RawAmounts -> Maybe Text
amountNegativeColor (RawAmounts _ _ value) = value

parseOptionalPresentationColor
  :: Text
  -> PresentationColor
  -> Maybe Text
  -> Either [Text] PresentationColor
parseOptionalPresentationColor _ fallback Nothing = Right fallback
parseOptionalPresentationColor path _ (Just value) =
  parsePresentationColor path value

parsePresentationColor :: Text -> Text -> Either [Text] PresentationColor
parsePresentationColor path value = case value of
  "red" -> Right RedColor
  "bright-red" -> Right BrightRedColor
  "green" -> Right GreenColor
  "yellow" -> Right YellowColor
  "blue" -> Right BlueColor
  "magenta" -> Right MagentaColor
  "cyan" -> Right CyanColor
  "white" -> Right WhiteColor
  _ -> Left
    [ path <> ": expected red, bright-red, green, yellow, blue, magenta, cyan, or white; got ‘"
        <> value <> "’"
    ]

parseAsOf :: Text -> RawAsOf -> Either [Text] AsOfSpec
parseAsOf path (RawAsOf value) =
  AsOf <$> parseDateReference path value

parseRange :: Text -> RawRange -> Either [Text] RangeSpec
parseRange path (RawRange start end) =
  RangeSpec
    <$> parseStartBoundary (path <> ".from") start
    <*> parseEndBoundary (path <> ".through") end

parseDailyFlow
  :: RawDailyFlow
  -> Either [Text] (RangeSpec, DateColumnCount)
parseDailyFlow (RawDailyFlow start end configuredColumns) = do
  rangeSpec <- parseRange "reports.daily-flow" (RawRange start end)
  dateColumns <- case configuredColumns of
    Nothing -> Right defaultDateColumnCount
    Just value -> integerToDateColumnCount value
  pure (rangeSpec, dateColumns)

parseRecent :: RawRecent -> Either [Text] RecentSpec
parseRecent (RawRecent end count) = do
  boundary <- parseEndBoundary "reports.recent-transactions.through" end
  countValue <- integerToCount count
  pure (RecentSpec boundary countValue)

parseDateReference :: Text -> Text -> Either [Text] DateReference
parseDateReference _ "latest" = Right Latest
parseDateReference path value =
  ExactDate <$> parseDayAt path value

parseStartBoundary :: Text -> Text -> Either [Text] StartBoundary
parseStartBoundary _ "beginning" = Right FromBeginning
parseStartBoundary path value =
  FromDate <$> parseDayAt path value

parseEndBoundary :: Text -> Text -> Either [Text] EndBoundary
parseEndBoundary _ "latest" = Right ThroughLatest
parseEndBoundary path value =
  ThroughDate <$> parseDayAt path value

parseDayAt :: Text -> Text -> Either [Text] Day
parseDayAt path value = case parseTimeM True defaultTimeLocale "%Y-%m-%d" (T.unpack value) of
  Just day -> Right day
  Nothing -> Left
    [ path <> ": expected latest, beginning where allowed, or YYYY-MM-DD; got ‘"
        <> value <> "’"
    ]

integerToCount :: Integer -> Either [Text] RecentCount
integerToCount count
  | count > toInteger (maxBound :: Int) = Left
      ["reports.recent-transactions.count: value is too large"]
  | otherwise = case mkRecentCount (fromInteger count) of
      Right value -> Right value
      Left _ -> Left
        ["reports.recent-transactions.count: expected a positive integer"]

integerToDateColumnCount :: Integer -> Either [Text] DateColumnCount
integerToDateColumnCount count
  | count > toInteger (maxBound :: Int) = Left
      ["reports.daily-flow.max-date-columns: value is too large"]
  | otherwise = case mkDateColumnCount (fromInteger count) of
      Right value -> Right value
      Left _ -> Left
        ["reports.daily-flow.max-date-columns: expected a positive integer"]
