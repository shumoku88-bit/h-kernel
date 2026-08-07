{-# LANGUAGE OverloadedStrings #-}

-- | Household Daily Target selection metadata carried by the canonical
-- @plan.journal@ without making that meaning part of the core Plan owner.
--
-- 'HKernel.Plan.Journal' owns Plan identity and accounting shape. This adapter
-- reads only @daily-target-id@ and optional reservation metadata from the same
-- transaction blocks, then publishes source-independent Daily Target
-- selections.
module HKernel.Household.DailyTarget.PlanJournal
  ( DailyTargetPlanJournalError(..)
  , parseDailyTargetPlanJournalSelections
  ) where

import Data.Char (isSpace)
import Data.List (foldl')
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import HKernel.Household.DailyTarget
  ( DailyTargetObligationSelection
  , declareDailyTargetObligation
  , mkDailyTargetScopeId
  , selectDailyTargetObligation
  )
import HKernel.Money
  ( mkAmount
  , mkCommodity
  , parseQuantity
  )
import HKernel.Plan
  ( mkPositiveAmount
  )
import HKernel.Plan.Journal
  ( IdentifiedPlanTransaction
  , PlanJournal
  , identifiedPlanId
  , planJournalTransactions
  )
import HKernel.Plan.Reservation
  ( declarePlanReservation
  , mkReservationId
  )

-- | Privacy-preserving source-local failures. Invalid private values are never
-- retained in the diagnostic value.
data DailyTargetPlanJournalError
  = DailyTargetPlanJournalMetadataAlignmentMismatch Int Int
  | DuplicateDailyTargetPlanJournalMetadataKey Int Text
  | EmptyDailyTargetPlanJournalSelectionId Int
  | DailyTargetReservationWithoutSelection Int
  | IncompleteDailyTargetReservation Int
  | InvalidDailyTargetReservationId Int
  | InvalidDailyTargetReservationAmount Int
  | InvalidDailyTargetReservationCommodity Int
  | NonPositiveDailyTargetReservationAmount Int
  deriving (Eq, Show)

type LocatedLine = (Int, Text)

data LocatedMetadata = LocatedMetadata
  { locatedMetadataLine  :: Int
  , locatedMetadataKey   :: Text
  , locatedMetadataValue :: Text
  }

data TransactionMetadataBlock = TransactionMetadataBlock
  { transactionMetadata :: [LocatedMetadata]
  }

-- | Project Daily Target declarations from the same source text already
-- admitted as a 'PlanJournal'. Transactions without @daily-target-id@ are not
-- selected and produce no declaration.
parseDailyTargetPlanJournalSelections
  :: Text
  -> PlanJournal
  -> Either (NonEmpty DailyTargetPlanJournalError) [DailyTargetObligationSelection]
parseDailyTargetPlanJournalSelections input planJournal
  | transactionCount /= metadataCount = Left
      (DailyTargetPlanJournalMetadataAlignmentMismatch
        transactionCount metadataCount NonEmpty.:| [])
  | otherwise = case NonEmpty.nonEmpty allErrors of
      Just errors -> Left errors
      Nothing -> Right (mapMaybe admissionSelection admissions)
  where
    transactions = planJournalTransactions planJournal
    metadataBlocks = transactionMetadataBlocks input
    transactionCount = length transactions
    metadataCount = length metadataBlocks
    admissions = zipWith3 admit [1..] transactions metadataBlocks
    allErrors = concatMap admissionErrors admissions

data SelectionAdmission = SelectionAdmission
  { admissionErrors    :: [DailyTargetPlanJournalError]
  , admissionSelection :: Maybe DailyTargetObligationSelection
  }

admit
  :: Int
  -> IdentifiedPlanTransaction
  -> TransactionMetadataBlock
  -> SelectionAdmission
admit transactionIndex identified block =
  case duplicateErrors of
    _ : _ -> SelectionAdmission duplicateErrors Nothing
    [] -> case selectionValue of
      Nothing
        | anyReservationValue -> SelectionAdmission
            [DailyTargetReservationWithoutSelection transactionIndex]
            Nothing
        | otherwise -> SelectionAdmission [] Nothing
      Just rawSelectionId ->
        case mkDailyTargetScopeId rawSelectionId of
          Left _ -> SelectionAdmission
            [EmptyDailyTargetPlanJournalSelectionId transactionIndex]
            Nothing
          Right selectionId ->
            case reservationResult of
              Left errors -> SelectionAdmission errors Nothing
              Right reservation -> SelectionAdmission []
                (Just
                  (selectDailyTargetObligation selectionId
                    (declareDailyTargetObligation
                      (identifiedPlanId identified)
                      reservation)))
  where
    metadata = transactionMetadata block
    duplicates = duplicateMetadataKeys metadata
    duplicateErrors =
      [ DuplicateDailyTargetPlanJournalMetadataKey lineNumber key
      | (lineNumber, key) <- duplicates
      ]
    values = Map.fromList
      [ (locatedMetadataKey entry, locatedMetadataValue entry)
      | entry <- metadata
      ]
    selectionValue = Map.lookup "daily-target-id" values
    reservationIdValue = Map.lookup "reservation-id" values
    reservationAmountValue = Map.lookup "reservation-amount" values
    reservationCommodityValue = Map.lookup "reservation-commodity" values
    reservationValues =
      [ reservationIdValue
      , reservationAmountValue
      , reservationCommodityValue
      ]
    anyReservationValue = any isPresent reservationValues
    allReservationValues = all isPresent reservationValues
    isPresent = maybe False (const True)

    reservationResult
      | not anyReservationValue = Right Nothing
      | not allReservationValues =
          Left [IncompleteDailyTargetReservation transactionIndex]
      | otherwise = case
          ( reservationIdValue
          , reservationAmountValue
          , reservationCommodityValue
          ) of
          (Just rawReservationId, Just rawAmount, Just rawCommodity) ->
            case mkReservationId rawReservationId of
              Left _ -> Left [InvalidDailyTargetReservationId transactionIndex]
              Right reservationId -> case parseQuantity rawAmount of
                Left _ -> Left [InvalidDailyTargetReservationAmount transactionIndex]
                Right quantity -> case mkCommodity rawCommodity of
                  Left _ -> Left
                    [InvalidDailyTargetReservationCommodity transactionIndex]
                  Right commodity -> case mkPositiveAmount
                      (mkAmount commodity quantity) of
                    Left _ -> Left
                      [NonPositiveDailyTargetReservationAmount transactionIndex]
                    Right positive -> Right
                      (Just
                        (declarePlanReservation
                          reservationId
                          (identifiedPlanId identified)
                          positive))
          _ -> Left [IncompleteDailyTargetReservation transactionIndex]

transactionMetadataBlocks :: Text -> [TransactionMetadataBlock]
transactionMetadataBlocks input =
  [ TransactionMetadataBlock
      { transactionMetadata = mapMaybe relevantMetadata (drop 1 block)
      }
  | block@((_, header) : _) <- sourceBlocks input
  , not (isNonTransactionDirective header)
  ]

sourceBlocks :: Text -> [[LocatedLine]]
sourceBlocks = map reverse . reverse . foldl' addLine [] . zip [1..] . T.lines
  where
    addLine blocks located@(_, line)
      | startsBlock line = [located] : blocks
      | otherwise = case blocks of
          [] -> []
          block : rest -> (located : block) : rest

startsBlock :: Text -> Bool
startsBlock line =
  not (T.null (T.strip line))
    && not (isIndented line)
    && not (isComment line)

relevantMetadata :: LocatedLine -> Maybe LocatedMetadata
relevantMetadata (lineNumber, line)
  | not (isIndented line && isComment line) = Nothing
  | normalizedKey `notElem` supportedKeys = Nothing
  | otherwise = Just LocatedMetadata
      { locatedMetadataLine = lineNumber
      , locatedMetadataKey = normalizedKey
      , locatedMetadataValue = T.strip (T.drop 1 remainder)
      }
  where
    cleanLine = T.strip
      (T.dropWhile (\character -> character == ';' || isSpace character)
        (T.strip line))
    (key, remainder) = T.breakOn ":" cleanLine
    normalizedKey = T.toCaseFold (T.strip key)

supportedKeys :: [Text]
supportedKeys =
  [ "daily-target-id"
  , "reservation-id"
  , "reservation-amount"
  , "reservation-commodity"
  ]

duplicateMetadataKeys :: [LocatedMetadata] -> [(Int, Text)]
duplicateMetadataKeys = reverse . third . foldl' observe (Map.empty, [], [])
  where
    observe (seen, unique, repeated) entry
      | Map.member key seen =
          (seen, unique, (locatedMetadataLine entry, key) : repeated)
      | otherwise = (Map.insert key () seen, entry : unique, repeated)
      where
        key = locatedMetadataKey entry
    third (_, _, value) = value

isNonTransactionDirective :: Text -> Bool
isNonTransactionDirective line =
  any (`isDirective` line) ["account", "include", "commodity"]

isDirective :: Text -> Text -> Bool
isDirective keyword line = case T.stripPrefix keyword (T.stripStart line) of
  Nothing -> False
  Just remainder ->
    T.null remainder
      || maybe False (isSpace . fst) (T.uncons remainder)

isComment :: Text -> Bool
isComment = T.isPrefixOf ";" . T.stripStart

isIndented :: Text -> Bool
isIndented line = case T.uncons line of
  Just (character, _) -> isSpace character
  Nothing -> False
