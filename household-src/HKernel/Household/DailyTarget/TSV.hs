{-# LANGUAGE OverloadedStrings #-}

-- | Admission for the retained @daily_target_scope.tsv@ surface.
--
-- The file currently carries two different meanings: long-lived eligible Asset
-- policy and cycle-varying Plan obligation declarations. This parser preserves
-- that physical compatibility surface while producing separate typed values.
module HKernel.Household.DailyTarget.TSV
  ( DailyTargetTSVError(..)
  , parseDailyTargetScope
  ) where

import Data.Either (partitionEithers)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import HKernel.Account
import HKernel.Household.DailyTarget
import HKernel.Money
import HKernel.Plan
import HKernel.Plan.Reservation

-- | Source-local diagnostic that retains a line coordinate without retaining a
-- complete private row.
data DailyTargetTSVError = DailyTargetTSVError
  { dailyTargetTSVErrorLine    :: Int
  , dailyTargetTSVErrorMessage :: Text
  } deriving (Eq, Show)

data ParsedRow
  = ParsedAsset Int Text Account
  | ParsedObligation Int Text DailyTargetObligationDeclaration
  deriving (Eq, Show)

parseDailyTargetScope
  :: AccountRegistry
  -> [CommittedOutgoingPlan]
  -> Text
  -> Either (NonEmpty DailyTargetTSVError) DailyTargetScope
parseDailyTargetScope registry plans input = case meaningfulLines input of
  [] -> Left (errorAt 1 "missing header" NonEmpty.:| [])
  (_, header) : rows
    | header /= expectedHeader ->
        Left (errorAt 1 "unexpected header" NonEmpty.:| [])
    | otherwise -> finish (map parseRow rows)
  where
    finish parsed =
      case NonEmpty.nonEmpty allErrors of
        Just admissionErrors -> Left admissionErrors
        Nothing -> case (policyResult, obligationResult) of
          (Right policy, Right resolvedObligations) ->
            Right (dailyTargetScope policy resolvedObligations)
          _ -> error "Daily Target admission lost a reported error"
      where
        (syntaxErrors, parsedRows) = partitionEithers parsed
        scopeErrors =
          [ errorAt line
              ("duplicate scope_id " <> quoted scopeId)
          | (scopeId, line) <- duplicateCoordinates
              [ (scopeIdentity value, rowLine value)
              | value <- parsedRows
              ]
          ]
        assets =
          [ account
          | ParsedAsset _ _ account <- parsedRows
          ]
        declarations =
          [ declaration
          | ParsedObligation _ _ declaration <- parsedRows
          ]
        policyResult = mkDailyTargetPolicy registry assets
        obligationResult =
          resolveDailyTargetObligationScope plans declarations
        policyErrors = either
          (map (errorAt 0 . T.pack . show) . NonEmpty.toList)
          (const [])
          policyResult
        obligationErrors = either
          (map (errorAt 0 . T.pack . show) . NonEmpty.toList)
          (const [])
          obligationResult
        allErrors =
          syntaxErrors ++ scopeErrors ++ policyErrors ++ obligationErrors

expectedHeader :: Text
expectedHeader = T.intercalate "\t"
  [ "kind", "scope_id", "account_key", "plan_id"
  , "excluded_amount", "currency", "reservation_ref"
  ]

parseRow :: (Int, Text) -> Either DailyTargetTSVError ParsedRow
parseRow (lineNumber, line) = case T.splitOn "\t" line of
  ["asset", scopeId, accountText, "", "", "", ""] -> do
    requireScopeId lineNumber scopeId
    account <- mapLeft (errorAt lineNumber . T.pack . show)
      (mkAccount accountText)
    Right (ParsedAsset lineNumber scopeId account)
  ["obligation", scopeId, "", rawPlanId, amountText, currencyText, reservationRef] -> do
    requireScopeId lineNumber scopeId
    planId <- mapLeft (errorAt lineNumber . T.pack . show)
      (mkPlanId rawPlanId)
    reservation <- parseReservation
      lineNumber planId amountText currencyText reservationRef
    Right (ParsedObligation lineNumber scopeId
      (declareDailyTargetObligation planId reservation))
  _ -> Left (errorAt lineNumber "invalid asset or obligation scope row")

parseReservation
  :: Int
  -> PlanId
  -> Text
  -> Text
  -> Text
  -> Either DailyTargetTSVError (Maybe PlanReservationDeclaration)
parseReservation _ _ "" "" "" = Right Nothing
parseReservation lineNumber planId amountText currencyText reservationRef
  | T.null amountText || T.null currencyText || T.null reservationRef =
      Left (errorAt lineNumber
        "excluded amount, currency, and reservation_ref must be supplied together")
  | otherwise = do
      quantity <- mapLeft (errorAt lineNumber . T.pack . show)
        (parseQuantity amountText)
      commodity <- mapLeft (errorAt lineNumber . T.pack . show)
        (mkCommodity currencyText)
      amount <- mapLeft (errorAt lineNumber . T.pack . show)
        (mkPositiveAmount (mkAmount commodity quantity))
      reservationId <- mapLeft (errorAt lineNumber . T.pack . show)
        (mkReservationId reservationRef)
      Right (Just (declarePlanReservation reservationId planId amount))

requireScopeId :: Int -> Text -> Either DailyTargetTSVError ()
requireScopeId lineNumber scopeId
  | T.null scopeId = Left (errorAt lineNumber "scope_id must be non-empty")
  | otherwise = Right ()

scopeIdentity :: ParsedRow -> Text
scopeIdentity row = case row of
  ParsedAsset _ scopeId _ -> scopeId
  ParsedObligation _ scopeId _ -> scopeId

rowLine :: ParsedRow -> Int
rowLine row = case row of
  ParsedAsset lineNumber _ _ -> lineNumber
  ParsedObligation lineNumber _ _ -> lineNumber

meaningfulLines :: Text -> [(Int, Text)]
meaningfulLines =
  filter (not . ignored . snd) . zip [1..] . T.lines
  where
    ignored line =
      let stripped = T.strip line
      in T.null stripped || "#" `T.isPrefixOf` stripped

-- | Return the line of every occurrence after the first for a repeated key.
duplicateCoordinates :: Ord key => [(key, Int)] -> [(key, Int)]
duplicateCoordinates = reverse . third . foldl observe (Map.empty, [], [])
  where
    observe (seen, unique, repeated) coordinate@(key, _)
      | Map.member key seen = (seen, unique, coordinate : repeated)
      | otherwise = (Map.insert key () seen, coordinate : unique, repeated)
    third (_, _, value) = value

errorAt :: Int -> Text -> DailyTargetTSVError
errorAt = DailyTargetTSVError

quoted :: Text -> Text
quoted value = "‘" <> value <> "’"

mapLeft :: (left -> right) -> Either left value -> Either right value
mapLeft f result = case result of
  Left err -> Left (f err)
  Right value -> Right value
