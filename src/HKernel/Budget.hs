{-# LANGUAGE OverloadedStrings #-}

-- | Pure identities and boundaries for the household budget compatibility model.
--
-- Envelope identity is owned by 'HKernel.Envelope.Identity' and re-exported
-- here while existing Budget modules migrate to the Envelope domain.
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

import Data.Text (Text)
import Data.Time.Calendar (Day)
import HKernel.Envelope.Identity
  ( EnvelopeId
  , EnvelopeIdError(..)
  , envelopeIdText
  , mkEnvelopeId
  )
import HKernel.Money (Amount)

-- | One budget period represented as @[start, endExclusive)@.
--
-- The constructor is hidden so an empty or backwards cycle cannot enter the
-- compatibility model.
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

budgetObservationContains :: BudgetObservation -> Day -> Bool
budgetObservationContains observation day =
  budgetCycleContains (budgetObservationCycle observation) day
    && day <= budgetObservationObservedThrough observation

-- | Retained Daily/Flex vocabulary until policy consumers move to EnvelopeMode.
data Pacing
  = Daily
  | Flex
  deriving (Eq, Ord, Show)

-- | Retained signed entitlement-change value used by the existing Budget path.
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
