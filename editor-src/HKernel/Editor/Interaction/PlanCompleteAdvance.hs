{-# LANGUAGE OverloadedStrings #-}

-- | Delivery-neutral interaction input for Plan Complete & Advance.
--
-- The TUI owns focus and event routing; this module owns only the editable
-- coordinates and their admission into the typed operation intent.
module HKernel.Editor.Interaction.PlanCompleteAdvance
  ( PlanCompleteAdvanceInput(..)
  , PlanCompleteAdvanceInputError(..)
  , initialPlanCompleteAdvanceInput
  , parsePlanCompleteAdvanceInput
  ) where

import Data.Bifunctor (first)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, parseTimeM)

import HKernel.Editor.PlanCompleteAdvance
  ( PlanAdvanceProposal(..)
  , PlanCompleteAdvanceIntent(..)
  , PositivePlanMagnitude
  , mkPositivePlanMagnitude
  )
import HKernel.Money (parseQuantity)

data PlanCompleteAdvanceInput = PlanCompleteAdvanceInput
  { planActualDateText      :: Text
  , planActualAmountText    :: Text
  , planSuccessorDateText   :: Text
  , planSuccessorAmountText :: Text
  } deriving (Eq, Show)

data PlanCompleteAdvanceInputError
  = PlanCompleteAdvanceInvalidActualDate
  | PlanCompleteAdvanceInvalidActualAmount
  | PlanCompleteAdvanceInvalidSuccessorDate
  | PlanCompleteAdvanceInvalidSuccessorAmount
  deriving (Eq, Show)

initialPlanCompleteAdvanceInput
  :: Day
  -> PlanAdvanceProposal
  -> PlanCompleteAdvanceInput
initialPlanCompleteAdvanceInput today proposal = PlanCompleteAdvanceInput
  { planActualDateText = T.pack (show today)
  , planActualAmountText = ""
  , planSuccessorDateText = maybe "" (T.pack . show)
      (proposalSuggestedNextDate proposal)
  , planSuccessorAmountText = ""
  }

parsePlanCompleteAdvanceInput
  :: PlanAdvanceProposal
  -> PlanCompleteAdvanceInput
  -> Either PlanCompleteAdvanceInputError PlanCompleteAdvanceIntent
parsePlanCompleteAdvanceInput proposal input = do
  actualDate <- parseDate PlanCompleteAdvanceInvalidActualDate
    (planActualDateText input)
  actualAmount <- parseOptionalAmount PlanCompleteAdvanceInvalidActualAmount
    (planActualAmountText input)
  successorDate <- parseOptionalDate PlanCompleteAdvanceInvalidSuccessorDate
    (planSuccessorDateText input)
  successorAmount <- parseOptionalAmount PlanCompleteAdvanceInvalidSuccessorAmount
    (planSuccessorAmountText input)
  pure PlanCompleteAdvanceIntent
    { completeAdvancePlanId = proposalPlanId proposal
    , completeAdvanceActualDate = actualDate
    , completeAdvanceActualAmount = actualAmount
    , completeAdvanceSuccessorDate = successorDate
    , completeAdvanceSuccessorAmount = successorAmount
    }

parseDate :: PlanCompleteAdvanceInputError -> Text -> Either PlanCompleteAdvanceInputError Day
parseDate errorValue value =
  maybe (Left errorValue) Right
    (parseTimeM True defaultTimeLocale "%Y-%m-%d" (T.unpack (T.strip value)))

parseOptionalDate
  :: PlanCompleteAdvanceInputError
  -> Text
  -> Either PlanCompleteAdvanceInputError (Maybe Day)
parseOptionalDate errorValue value
  | T.null stripped = Right Nothing
  | otherwise = Just <$> parseDate errorValue stripped
  where
    stripped = T.strip value

parseOptionalAmount
  :: PlanCompleteAdvanceInputError
  -> Text
  -> Either PlanCompleteAdvanceInputError (Maybe PositivePlanMagnitude)
parseOptionalAmount errorValue value
  | T.null stripped = Right Nothing
  | otherwise = do
      quantity <- first (const errorValue) (parseQuantity stripped)
      positive <- first (const errorValue) (mkPositivePlanMagnitude quantity)
      pure (Just positive)
  where
    stripped = T.strip value
