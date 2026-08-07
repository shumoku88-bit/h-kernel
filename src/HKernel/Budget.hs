{-# LANGUAGE OverloadedStrings #-}

-- | Pure identities and boundaries for the household budget model.
--
-- This module does not parse files, inspect a 'Journal', calculate envelope
-- balances, or render a report. It gives later adapters and calculations one
-- small typed vocabulary for half-open cycles, point-in-time observation,
-- spendable envelope identity, pacing, and exact dated entitlement changes.
module HKernel.Budget
  ( BudgetCycle
  , BudgetCycleError(..)
  , mkBudgetCycle
  , budgetCycleStart
  , budgetCycleEndExclusive
  , budgetCycleContains
  , BudgetObservation
  , BudgetObservationError(..)
  , mkBudgetObservation
  , budgetObservationCycle
  , budgetObservationObservedThrough
  , budgetObservationContains
  , EnvelopeId
  , EnvelopeIdError(..)
  , mkEnvelopeId
  , envelopeIdText
  , Pacing(..)
  , BudgetChange
  , BudgetChangeError(..)
  , mkBudgetChange
  , budgetChangeDate
  , budgetChangeCycle
  , budgetChangeEnvelope
  , budgetChangeAmount
  , budgetChangeNote
  ) where

import Data.Char (isControl, isSpace)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import HKernel.Money (Amount)

-- | One budget period represented as @[start, endExclusive)@.
--
-- The constructor is hidden so an empty or backwards cycle cannot enter the
-- budget model.
data BudgetCycle = BudgetCycle
  { budgetCycleStart        :: Day
  , budgetCycleEndExclusive :: Day
  } deriving (Eq, Ord, Show)

data BudgetCycleError = BudgetCycleDoesNotAdvance
  { invalidBudgetCycleStart        :: Day
  , invalidBudgetCycleEndExclusive :: Day
  } deriving (Eq, Show)

mkBudgetCycle :: Day -> Day -> Either BudgetCycleError BudgetCycle
mkBudgetCycle start endExclusive
  | start < endExclusive = Right (BudgetCycle start endExclusive)
  | otherwise = Left (BudgetCycleDoesNotAdvance start endExclusive)

budgetCycleContains :: BudgetCycle -> Day -> Bool
budgetCycleContains cycle day =
  day >= budgetCycleStart cycle
    && day < budgetCycleEndExclusive cycle

-- | One point-in-time observation inside a budget cycle.
--
-- @observedThrough@ is inclusive. The hidden constructor guarantees that the
-- observation day belongs to the selected half-open cycle, so Entitlement,
-- Consumption, Remaining, and later Backing calculations can share one horizon.
data BudgetObservation = BudgetObservation
  { budgetObservationCycle           :: BudgetCycle
  , budgetObservationObservedThrough :: Day
  } deriving (Eq, Ord, Show)

data BudgetObservationError = BudgetObservationOutsideCycle
  { invalidBudgetObservationDay   :: Day
  , invalidBudgetObservationCycle :: BudgetCycle
  } deriving (Eq, Show)

mkBudgetObservation
  :: BudgetCycle
  -> Day
  -> Either BudgetObservationError BudgetObservation
mkBudgetObservation cycle observedThrough
  | budgetCycleContains cycle observedThrough =
      Right (BudgetObservation cycle observedThrough)
  | otherwise =
      Left (BudgetObservationOutsideCycle observedThrough cycle)

-- | Whether one date is visible in this inclusive point-in-time observation.
budgetObservationContains :: BudgetObservation -> Day -> Bool
budgetObservationContains observation day =
  budgetCycleContains (budgetObservationCycle observation) day
    && day <= budgetObservationObservedThrough observation

-- | Stable machine identity for one spendable envelope.
--
-- Human-facing labels belong to budget policy. The reserved identity
-- @unallocated@ is deliberately rejected because Unallocated is a derived
-- backing remainder, not a spendable envelope or allocation destination.
newtype EnvelopeId = EnvelopeId { envelopeIdText :: Text }
  deriving (Eq, Ord, Show)

data EnvelopeIdError
  = EmptyEnvelopeId
  | EnvelopeIdHasSurroundingWhitespace Text
  | EnvelopeIdContainsControlCharacter Text
  | EnvelopeIdContainsWhitespace Text
  | ReservedEnvelopeId Text
  deriving (Eq, Show)

mkEnvelopeId :: Text -> Either EnvelopeIdError EnvelopeId
mkEnvelopeId value
  | T.null value = Left EmptyEnvelopeId
  | T.strip value /= value =
      Left (EnvelopeIdHasSurroundingWhitespace value)
  | T.any isControl value =
      Left (EnvelopeIdContainsControlCharacter value)
  | T.any isSpace value = Left (EnvelopeIdContainsWhitespace value)
  | T.toCaseFold value == "unallocated" = Left (ReservedEnvelopeId value)
  | otherwise = Right (EnvelopeId value)

-- | How one spendable envelope participates in pace reporting.
--
-- Daily envelopes are divided over remaining cycle days. Flex envelopes retain
-- a cycle balance without contributing to the daily allowance.
data Pacing
  = Daily
  | Flex
  deriving (Eq, Ord, Show)

-- | One irreducible dated entitlement change.
--
-- Positive and negative exact 'Amount' values use the same shape, so an initial
-- allocation and a later adjustment are not separate event types.
data BudgetChange = BudgetChange
  { budgetChangeDate     :: Day
  , budgetChangeCycle    :: BudgetCycle
  , budgetChangeEnvelope :: EnvelopeId
  , budgetChangeAmount   :: Amount
  , budgetChangeNote     :: Text
  } deriving (Eq, Show)

data BudgetChangeError = BudgetChangeOutsideCycle
  { invalidBudgetChangeDate  :: Day
  , invalidBudgetChangeCycle :: BudgetCycle
  } deriving (Eq, Show)

mkBudgetChange
  :: Day
  -> BudgetCycle
  -> EnvelopeId
  -> Amount
  -> Text
  -> Either BudgetChangeError BudgetChange
mkBudgetChange day cycle envelope amount note
  | budgetCycleContains cycle day = Right BudgetChange
      { budgetChangeDate = day
      , budgetChangeCycle = cycle
      , budgetChangeEnvelope = envelope
      , budgetChangeAmount = amount
      , budgetChangeNote = note
      }
  | otherwise = Left (BudgetChangeOutsideCycle day cycle)
