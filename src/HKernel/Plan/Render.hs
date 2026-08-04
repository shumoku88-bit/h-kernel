{-# LANGUAGE OverloadedStrings #-}

-- | Pure one-line rendering for admitted committed Plans.
--
-- Completion state is deliberately absent from this first projection. A later
-- Plan-to-Actual relation must derive that evidence before the report may label a
-- Plan open, completed, duplicate, or ambiguous.
module HKernel.Plan.Render
  ( renderCommittedOutgoingPlanLine
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, formatTime)
import HKernel.Account (accountName, declaredAccount)
import HKernel.Money
  ( Amount
  , amountCommodity
  , amountQuantity
  , commodityCode
  , renderQuantity
  )
import HKernel.Plan

renderCommittedOutgoingPlanLine :: CommittedOutgoingPlan -> Text
renderCommittedOutgoingPlanLine plan = T.intercalate " | "
  [ renderDay (committedPlanDate plan)
  , planIdText (committedPlanId plan)
  , renderAmount (positiveAmountValue (committedPlanAmount plan))
  , accountName (declaredAccount (declaredPaymentSource direction))
      <> " -> "
      <> accountName (declaredAccount (declaredPaymentDestination direction))
  , committedPlanMemo plan
  ]
  where
    direction = declaredOutgoingPaymentDirection
      (committedPlanDirection plan)

renderAmount :: Amount -> Text
renderAmount amount =
  renderQuantity (amountQuantity amount)
    <> " " <> commodityCode (amountCommodity amount)

renderDay :: Day -> Text
renderDay = T.pack . formatTime defaultTimeLocale "%Y-%m-%d"
