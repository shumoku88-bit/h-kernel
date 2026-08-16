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

import Data.Maybe (isJust)
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

data RawPresentation = RawPresentation
  { rawPresentationHierarchy :: Maybe RawHierarchy
  , rawPresentationAmounts :: Maybe RawAmounts
  , rawPresentationCalendar :: Maybe RawCalendar
  }

data RawHierarchy = RawHierarchy
  { rawHeadingColor :: Maybe Text
  , rawSectionColor :: Maybe Text
  }

data RawAmounts = RawAmounts
  { rawNegativeStyle :: Text
  , rawPositiveColor :: Maybe Text
  , rawNegativeColor :: Maybe Text
  }

-- | Canonical calendar presentation shape. The nested @markers@ table is read
-- only as a short migration bridge for already-published Household sources.
data RawCalendar = RawCalendar
  { rawCalendarCycleEndMarker :: Maybe Text
  , rawCalendarPlanDueMarker :: Maybe Text
  , rawCalendarIssueDueMarker :: Maybe Text
  , rawCalendarMultipleMarker :: Maybe Text
  , rawCalendarLegacyMarkers :: Maybe RawLegacyCalendarMarkers
  }

data RawLegacyCalendarMarkers = RawLegacyCalendarMarkers
  { rawLegacyCalendarActualMarker :: Maybe Text
  , rawLegacyCalendarPlanMarker :: Maybe Text
  , rawLegacyCalendarIssueDueMarker :: Maybe Text
  , rawLegacyCalendarCycleEndMarker :: Maybe Text
  }

data RawReports = RawReports
  RawAsOf
  RawAsOf
  RawRange
  RawDailyFlow
  RawRange
  RawRecent

data RawAsOf = RawAsOf Text

data RawRange = RawRange (Maybe Text) (Maybe Text) (Maybe Text)

data RawDailyFlow =
  RawDailyFlow (Maybe Text) (Maybe Text) (Maybe Text) (Maybe Integer)

data RawRecent = RawRecent Text Integer

instance FromValue RawConfig where
  fromValue = parseTableFromValue
    (RawConfig <$> optKey "presentation" <*> reqKey "reports")

instance FromValue RawPresentation where
  fromValue = parseTableFromValue
    (RawPresentation
      <$> optKey "hierarchy"
      <*> optKey "amounts"
      <*> optKey "calendar")

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

instance FromValue RawCalendar where
  fromValue = parseTableFromValue
    (RawCalendar
      <$> optKey "cycle-end-marker"
      <*> optKey "plan-due-marker"
      <*> optKey "issue-due-marker"
      <*> optKey "multiple-marker"
      <*> optKey "markers")

instance FromValue RawLegacyCalendarMarkers where
  fromValue = parseTableFromValue
    (RawLegacyCalendarMarkers
      <$> optKey "actual"
      <*> optKey "plan"
      <*> optKey "issue-due"
      <*> optKey "cycle-end")

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
    (RawRange
      <$> optKey "range"
      <*> optKey "from"
      <*> optKey "through")

instance FromValue RawDailyFlow where
  fromValue = parseTableFromValue
    (RawDailyFlow
      <$> optKey "range"
      <*> optKey "from"
      <*> optKey "through"
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
  ( [ "[presentation.hierarchy]"
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
    , "[presentation.calendar]"
    , "cycle-end-marker = " <> quotedCalendarMarker
        (calendarCycleEndMarker calendarMarkers)
    , "plan-due-marker = " <> quotedCalendarMarker
        (calendarPlanDueMarker calendarMarkers)
    , "issue-due-marker = " <> quotedCalendarMarker
        (calendarIssueDueMarker calendarMarkers)
    , "multiple-marker = " <> quotedCalendarMarker
        (calendarMultipleMarker calendarMarkers)
    , ""
    , "[reports.trial-balance]"
    , "as-of = " <> quoted (renderAsOf (trialBalanceSpec plan))
    , ""
    , "[reports.balance-sheet]"
    , "as-of = " <> quoted (renderAsOf (balanceSheetSpec plan))
    , ""
    , "[reports.profit-and-loss]"
    ]
    <> renderRangeLines (profitAndLossSpec plan)
    <> [ ""
       , "[reports.daily-flow]"
       ]
    <> renderRangeLines (dailyFlowSpec plan)
    <> [ "max-date-columns = " <> T.pack
          (show (dateColumnCountValue
            (presentationDailyFlowDateColumns presentation)))
       , ""
       , "[reports.monthly-accounts]"
       ]
    <> renderRangeLines (monthlyAccountsSpec plan)
    <> [ ""
       , "[reports.recent-transactions]"
       , "through = " <> quoted (renderEndBoundary
           (recentSpecThrough (recentTransactionsSpec plan)))
       , "count = " <> T.pack
           (show (recentCountValue
             (recentSpecCount (recentTransactionsSpec plan))))
       ]
  )
  where
    plan = reportConfigurationPlan configuration
    presentation = reportConfigurationPresentation configuration
    calendarMarkers = presentationCalendarMarkers presentation

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

renderRangeLines :: RangeSpec -> [Text]
renderRangeLines CurrentCycleToDate =
  ["range = \"current-cycle-to-date\""]
renderRangeLines (RangeSpec start end) =
  [ "from = " <> quoted (renderStartBoundary start)
  , "through = " <> quoted (renderEndBoundary end)
  ]

renderStartBoundary :: StartBoundary -> Text
renderStartBoundary FromBeginning = "beginning"
renderStartBoundary (FromDate day) = renderDay day

renderEndBoundary :: EndBoundary -> Text
renderEndBoundary ThroughLatest = "latest"
renderEndBoundary (ThroughDate day) = renderDay day

renderDay :: Day -> Text
renderDay = T.pack . formatTime defaultTimeLocale "%F"

quotedCalendarMarker :: CalendarMarker -> Text
quotedCalendarMarker = quoted . T.singleton . calendarMarkerValue

quoted :: Text -> Text
quoted value = "\"" <> T.concatMap escapeBasicString value <> "\""
  where
    escapeBasicString '\\' = "\\\\"
    escapeBasicString '"' = "\\\""
    escapeBasicString character = T.singleton character

renderReportConfigErrors :: [Text] -> Text
renderReportConfigErrors = T.unlines . map ("  " <>)

rawConfigToConfiguration :: RawConfig -> Either [Text] ReportConfiguration
rawConfigToConfiguration (RawConfig rawPresentation reports) = case reports of
  RawReports trial balance profit daily monthly recent -> do
    negativeStyle <- parseNegativeStyle amounts
    headingColor <- parseOptionalPresentationColor
      "presentation.hierarchy.heading-color"
      CyanColor
      (hierarchy >>= rawHeadingColor)
    sectionColor <- parseOptionalPresentationColor
      "presentation.hierarchy.section-color"
      YellowColor
      (hierarchy >>= rawSectionColor)
    positiveAmountColor <- parseOptionalPresentationColor
      "presentation.amounts.positive-color"
      GreenColor
      (amounts >>= rawPositiveColor)
    negativeAmountColor <- parseOptionalPresentationColor
      "presentation.amounts.negative-color"
      RedColor
      (amounts >>= rawNegativeColor)
    calendarMarkers <- parseCalendarMarkers calendar
    trialSpec <- parseAsOf "reports.trial-balance.as-of" trial
    balanceSpec <- parseAsOf "reports.balance-sheet.as-of" balance
    profitSpec <- parseRange True "reports.profit-and-loss" profit
    (dailySpec', dateColumns) <- parseDailyFlow daily
    monthlySpec <- parseRange False "reports.monthly-accounts" monthly
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
          , presentationCalendarMarkers = calendarMarkers
          , presentationDailyFlowDateColumns = dateColumns
          }
      }
    where
      hierarchy = rawPresentation >>= rawPresentationHierarchy
      amounts = rawPresentation >>= rawPresentationAmounts
      calendar = rawPresentation >>= rawPresentationCalendar

parseNegativeStyle :: Maybe RawAmounts -> Either [Text] NegativeStyle
parseNegativeStyle Nothing = Right AccountingParentheses
parseNegativeStyle (Just amounts) = case rawNegativeStyle amounts of
  "parentheses" -> Right AccountingParentheses
  "minus" -> Right LeadingMinus
  value -> Left
    [ "presentation.amounts.negative-style: expected parentheses or minus; got ‘"
        <> value <> "’"
    ]

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

parseCalendarMarkers :: Maybe RawCalendar -> Either [Text] CalendarMarkers
parseCalendarMarkers Nothing = Right defaultCalendarMarkers
parseCalendarMarkers (Just raw) =
  case rawCalendarLegacyMarkers raw of
    Just legacy
      | hasDirectCalendarMarker raw -> Left
          [ "presentation.calendar: legacy markers table cannot be combined with direct calendar marker keys" ]
      | otherwise -> parseLegacyCalendarMarkers legacy
    Nothing -> parseCanonicalCalendarMarkers raw

hasDirectCalendarMarker :: RawCalendar -> Bool
hasDirectCalendarMarker raw = any isJust
  [ rawCalendarCycleEndMarker raw
  , rawCalendarPlanDueMarker raw
  , rawCalendarIssueDueMarker raw
  , rawCalendarMultipleMarker raw
  ]

parseCanonicalCalendarMarkers :: RawCalendar -> Either [Text] CalendarMarkers
parseCanonicalCalendarMarkers raw = CalendarMarkers
  <$> parseOptionalCalendarMarker
      "presentation.calendar.plan-due-marker"
      (calendarPlanDueMarker defaultCalendarMarkers)
      (rawCalendarPlanDueMarker raw)
  <*> parseOptionalCalendarMarker
      "presentation.calendar.issue-due-marker"
      (calendarIssueDueMarker defaultCalendarMarkers)
      (rawCalendarIssueDueMarker raw)
  <*> parseOptionalCalendarMarker
      "presentation.calendar.cycle-end-marker"
      (calendarCycleEndMarker defaultCalendarMarkers)
      (rawCalendarCycleEndMarker raw)
  <*> parseOptionalCalendarMarker
      "presentation.calendar.multiple-marker"
      (calendarMultipleMarker defaultCalendarMarkers)
      (rawCalendarMultipleMarker raw)

-- | Current private Household data may still contain the old nested shape while
-- h-kernel and bqn-ledger converge. It remains readable, but canonical rendering
-- always publishes the direct shared shape above. The retired Actual glyph is
-- validated so legacy input does not silently become less strict.
parseLegacyCalendarMarkers
  :: RawLegacyCalendarMarkers
  -> Either [Text] CalendarMarkers
parseLegacyCalendarMarkers raw = do
  _ <- parseOptionalCalendarMarker
    "presentation.calendar.markers.actual"
    (calendarMultipleMarker defaultCalendarMarkers)
    (rawLegacyCalendarActualMarker raw)
  CalendarMarkers
    <$> parseOptionalCalendarMarker
        "presentation.calendar.markers.plan"
        (calendarPlanDueMarker defaultCalendarMarkers)
        (rawLegacyCalendarPlanMarker raw)
    <*> parseOptionalCalendarMarker
        "presentation.calendar.markers.issue-due"
        (calendarIssueDueMarker defaultCalendarMarkers)
        (rawLegacyCalendarIssueDueMarker raw)
    <*> parseOptionalCalendarMarker
        "presentation.calendar.markers.cycle-end"
        (calendarCycleEndMarker defaultCalendarMarkers)
        (rawLegacyCalendarCycleEndMarker raw)
    <*> pure (calendarMultipleMarker defaultCalendarMarkers)

parseOptionalCalendarMarker
  :: Text
  -> CalendarMarker
  -> Maybe Text
  -> Either [Text] CalendarMarker
parseOptionalCalendarMarker _ fallback Nothing = Right fallback
parseOptionalCalendarMarker path _ (Just value) =
  case mkCalendarMarker value of
    Right marker -> Right marker
    Left _ -> Left
      [ path
          <> ": expected exactly one printable non-space ASCII character; got ‘"
          <> value <> "’"
      ]

parseAsOf :: Text -> RawAsOf -> Either [Text] AsOfSpec
parseAsOf path (RawAsOf value) =
  AsOf <$> parseDateReference path value

parseRange :: Bool -> Text -> RawRange -> Either [Text] RangeSpec
parseRange allowCurrentCycle path (RawRange symbolic start end) =
  case (symbolic, start, end) of
    (Just value, Nothing, Nothing) -> parseSymbolicRange allowCurrentCycle path value
    (Nothing, Just startValue, Just endValue) ->
      RangeSpec
        <$> parseStartBoundary (path <> ".from") startValue
        <*> parseEndBoundary (path <> ".through") endValue
    (Just _, _, _) -> Left
      [path <> ": range cannot be combined with from or through"]
    (Nothing, _, _) -> Left
      [ path
          <> ": expected both from and through"
          <> if allowCurrentCycle then ", or range = \"current-cycle-to-date\"" else ""
      ]

parseSymbolicRange :: Bool -> Text -> Text -> Either [Text] RangeSpec
parseSymbolicRange True _ "current-cycle-to-date" = Right CurrentCycleToDate
parseSymbolicRange False path "current-cycle-to-date" = Left
  [path <> ".range: current-cycle-to-date is not supported for this report"]
parseSymbolicRange _ path value = Left
  [ path <> ".range: expected current-cycle-to-date; got ‘"
      <> value <> "’"
  ]

parseDailyFlow
  :: RawDailyFlow
  -> Either [Text] (RangeSpec, DateColumnCount)
parseDailyFlow (RawDailyFlow symbolic start end configuredColumns) = do
  rangeSpec <- parseRange True "reports.daily-flow" (RawRange symbolic start end)
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
