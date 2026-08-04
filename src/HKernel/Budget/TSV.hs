{-# LANGUAGE OverloadedStrings #-}

-- | Strict parser for the dated budget changes stored in @budget.tsv@.
--
-- The parser owns only file admission. It does not inspect a 'Journal', decode
-- budget policy, calculate consumption, or render a tracker. Source line
-- numbers are retained in diagnostics and malformed rows are never discarded.
module HKernel.Budget.TSV
  ( BudgetDateField(..)
  , BudgetTSVError(..)
  , BudgetTSVErrorReason(..)
  , parseBudgetTSV
  ) where

import Data.Either (partitionEithers)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import HKernel.Budget
import HKernel.Budget.History
  ( BudgetHistory
  , BudgetHistoryError(..)
  , mkBudgetHistory
  )
import HKernel.Money

-- | The date column whose text failed admission.
data BudgetDateField
  = ChangeDate
  | CycleStart
  | CycleEndExclusive
  deriving (Eq, Ord, Show)

data BudgetTSVError = BudgetTSVError
  { budgetTSVErrorLine   :: Int
  , budgetTSVErrorReason :: BudgetTSVErrorReason
  } deriving (Eq, Show)

data BudgetTSVErrorReason
  = MissingBudgetTSVHeader
  | InvalidBudgetTSVHeader Text
  | InvalidBudgetTSVRow Text
  | InvalidBudgetTSVDate BudgetDateField Text
  | InvalidBudgetTSVCycle BudgetCycleError
  | InvalidBudgetTSVEnvelope EnvelopeIdError
  | InvalidBudgetTSVQuantity QuantityError
  | InvalidBudgetTSVCommodity CommodityError
  | InvalidBudgetTSVChange BudgetChangeError
  | NegativeBudgetEntitlement
      BudgetCycle
      EnvelopeId
      Commodity
      Quantity
  deriving (Eq, Show)

-- | Parse the canonical seven-column budget change table.
--
-- The first meaningful line must be exactly:
--
-- @date<TAB>cycle_start<TAB>cycle_end_exclusive<TAB>envelope<TAB>quantity<TAB>commodity<TAB>note@
--
-- Blank lines and lines beginning with @#@ are ignored. Parsed changes retain
-- source order. Successful admission returns a 'BudgetHistory' whose hidden
-- constructor proves that effective-date entitlement never became negative.
parseBudgetTSV
  :: Text
  -> Either (NonEmpty BudgetTSVError) BudgetHistory
parseBudgetTSV input =
  case meaningfulLines of
    [] -> Left (atLine 1 MissingBudgetTSVHeader NonEmpty.:| [])
    headerLine : rowLines
      | snd headerLine /= budgetTSVHeader ->
          Left
            ( atLine (fst headerLine)
                (InvalidBudgetTSVHeader (snd headerLine))
                NonEmpty.:| []
            )
      | otherwise -> parseRows rowLines
  where
    meaningfulLines = filter (not . ignored . snd) (zip [1..] (T.lines input))

    ignored line =
      let stripped = T.strip line
      in T.null stripped || "#" `T.isPrefixOf` stripped

parseRows
  :: [(Int, Text)]
  -> Either (NonEmpty BudgetTSVError) BudgetHistory
parseRows rows =
  case NonEmpty.nonEmpty rowErrors of
    Just errors -> Left errors
    Nothing ->
      case mkBudgetHistory changes of
        Left historyErrors -> Left
          (fmap (historyErrorAt locatedChanges) historyErrors)
        Right history -> Right history
  where
    (rowErrors, locatedChanges) = partitionEithers (map parseRow rows)
    changes = map locatedBudgetChange locatedChanges

budgetTSVHeader :: Text
budgetTSVHeader = T.intercalate "\t"
  [ "date"
  , "cycle_start"
  , "cycle_end_exclusive"
  , "envelope"
  , "quantity"
  , "commodity"
  , "note"
  ]

data LocatedBudgetChange = LocatedBudgetChange
  { locatedBudgetChangeLine :: Int
  , locatedBudgetChange     :: BudgetChange
  }

parseRow
  :: (Int, Text)
  -> Either BudgetTSVError LocatedBudgetChange
parseRow (lineNumber, line) =
  case T.splitOn "\t" line of
    [ dateText
      , cycleStartText
      , cycleEndText
      , envelopeText
      , quantityText
      , commodityText
      , note
      ] -> do
        day <- parseDate lineNumber ChangeDate dateText
        cycleStart <- parseDate lineNumber CycleStart cycleStartText
        cycleEnd <- parseDate lineNumber CycleEndExclusive cycleEndText
        cycle <- mapError lineNumber InvalidBudgetTSVCycle
          (mkBudgetCycle cycleStart cycleEnd)
        envelope <- mapError lineNumber InvalidBudgetTSVEnvelope
          (mkEnvelopeId envelopeText)
        quantity <- mapError lineNumber InvalidBudgetTSVQuantity
          (parseQuantity quantityText)
        commodity <- mapError lineNumber InvalidBudgetTSVCommodity
          (mkCommodity commodityText)
        change <- mapError lineNumber InvalidBudgetTSVChange
          (mkBudgetChange
            day
            cycle
            envelope
            (mkAmount commodity quantity)
            note)
        Right (LocatedBudgetChange lineNumber change)
    _ -> Left (atLine lineNumber (InvalidBudgetTSVRow line))

parseDate
  :: Int
  -> BudgetDateField
  -> Text
  -> Either BudgetTSVError Day
parseDate lineNumber field input =
  case parseTimeM True defaultTimeLocale "%F" (T.unpack input) :: Maybe Day of
    Just day -> Right day
    Nothing  -> Left (atLine lineNumber (InvalidBudgetTSVDate field input))

mapError
  :: Int
  -> (error -> BudgetTSVErrorReason)
  -> Either error value
  -> Either BudgetTSVError value
mapError lineNumber wrap result = case result of
  Left err    -> Left (atLine lineNumber (wrap err))
  Right value -> Right value

atLine :: Int -> BudgetTSVErrorReason -> BudgetTSVError
atLine = BudgetTSVError

historyErrorAt
  :: [LocatedBudgetChange]
  -> BudgetHistoryError
  -> BudgetTSVError
historyErrorAt locatedChanges
    (BudgetHistoryNegativeEntitlement
      cycle
      envelope
      commodity
      day
      quantity) =
  atLine lineNumber
    (NegativeBudgetEntitlement cycle envelope commodity quantity)
  where
    matchingLines =
      [ locatedBudgetChangeLine located
      | located <- locatedChanges
      , let change = locatedBudgetChange located
      , let amount = budgetChangeAmount change
      , budgetChangeCycle change == cycle
      , budgetChangeEnvelope change == envelope
      , amountCommodity amount == commodity
      , budgetChangeDate change == day
      ]

    lineNumber = case NonEmpty.nonEmpty matchingLines of
      Just lines -> maximum (NonEmpty.toList lines)
      Nothing    -> 1
