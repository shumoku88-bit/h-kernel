{-# LANGUAGE OverloadedStrings #-}

-- | Delivery-neutral input state for the everyday Plan complete/advance flow.
module HKernel.Editor.Interaction.PlanCompleteAdvance
  ( PlanCompleteAdvanceInput(..)
  , PlanCompleteAdvanceInputError(..)
  , initialPlanCompleteAdvanceInput
  , setPlanActualDate
  , parsePlanCompleteAdvanceInput
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, parseTimeM)

import HKernel.Editor.PlanCompleteAdvance
  ( PlanAdvanceProposal(..)
  , PlanCompleteAdvanceIntent(..)
  )
import HKernel.Editor.PlanLifecycle
  ( PositivePlanFinishAmount
  , mkPositivePlanFinishAmount
  )
import HKernel.Money (parseQuantity)

data PlanCompleteAdvanceInput = PlanCompleteAdvanceInput
  { planActualDateText      :: Text
  , planActualAmountText    :: Text
  , planSuccessorDateText   :: Text
  , planSuccessorAmountText :: Text
  } deriving (Eq, Show)

data PlanCompleteAdvanceInputError
  = InvalidPlanActualDate
  | InvalidPlanActualAmount
  | InvalidPlanSuccessorDate
  | InvalidPlanSuccessorAmount
  | PlanSuccessorAmountWithoutDate
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

setPlanActualDate
  :: Day
  -> PlanCompleteAdvanceInput
  -> PlanCompleteAdvanceInput
setPlanActualDate day input =
  input { planActualDateText = T.pack (show day) }

parsePlanCompleteAdvanceInput
  :: PlanAdvanceProposal
  -> PlanCompleteAdvanceInput
  -> Either PlanCompleteAdvanceInputError PlanCompleteAdvanceIntent
parsePlanCompleteAdvanceInput proposal input = do
  actualDate <- parseDay InvalidPlanActualDate (planActualDateText input)
  actualAmount <- parseOptionalAmount InvalidPlanActualAmount
    (planActualAmountText input)
  successorDate <- parseOptionalDay (planSuccessorDateText input)
  successorAmount <- parseOptionalAmount InvalidPlanSuccessorAmount
    (planSuccessorAmountText input)
  case (successorDate, successorAmount) of
    (Nothing, Just _) -> Left PlanSuccessorAmountWithoutDate
    _ -> Right PlanCompleteAdvanceIntent
      { completeAdvancePlanId = proposalPlanId proposal
      , completeAdvanceActualDate = actualDate
      , completeAdvanceActualAmount = actualAmount
      , completeAdvanceSuccessorDate = successorDate
      , completeAdvanceSuccessorAmount = successorAmount
      }

parseOptionalDay :: Text -> Either PlanCompleteAdvanceInputError (Maybe Day)
parseOptionalDay value
  | T.null (T.strip value) = Right Nothing
  | otherwise = Just <$> parseDay InvalidPlanSuccessorDate value

parseDay
  :: PlanCompleteAdvanceInputError
  -> Text
  -> Either PlanCompleteAdvanceInputError Day
parseDay errorValue value =
  case parseTimeM True defaultTimeLocale "%Y-%m-%d" (T.unpack (T.strip value)) of
    Just day -> Right day
    Nothing -> Left errorValue

parseOptionalAmount
  :: PlanCompleteAdvanceInputError
  -> Text
  -> Either PlanCompleteAdvanceInputError (Maybe PositivePlanFinishAmount)
parseOptionalAmount errorValue value
  | T.null (T.strip value) = Right Nothing
  | otherwise = case parseQuantity (T.strip value) of
      Left _ -> Left errorValue
      Right quantity -> case mkPositivePlanFinishAmount quantity of
        Left _ -> Left errorValue
        Right amount -> Right (Just amount)
