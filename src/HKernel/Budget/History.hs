-- | Validated history of exact dated budget changes.
--
-- This module owns the cross-change invariant that cumulative entitlement never
-- becomes negative at any cycle, envelope, commodity, and effective date. File
-- adapters may add source-location diagnostics, while later calculations can
-- depend on 'BudgetHistory' as admission evidence.
module HKernel.Budget.History
  ( BudgetHistory
  , budgetHistoryChanges
  , BudgetHistoryError(..)
  , mkBudgetHistory
  ) where

import Data.List (find, mapAccumL)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Time.Calendar (Day)
import HKernel.Budget
  ( BudgetChange
  , BudgetCycle
  , EnvelopeId
  , budgetChangeAmount
  , budgetChangeCycle
  , budgetChangeDate
  , budgetChangeEnvelope
  )
import HKernel.Money
  ( Commodity
  , Quantity
  , addQuantity
  , amountCommodity
  , amountQuantity
  , zeroQuantity
  )

-- | Budget changes admitted as one coherent entitlement history.
--
-- Source order is retained for provenance and later publication. The hidden
-- constructor guarantees that effective-date accumulation never falls below
-- zero at any entitlement coordinate.
newtype BudgetHistory = BudgetHistory
  { budgetHistoryChanges :: [BudgetChange]
  } deriving (Eq, Show)

-- | A coordinate whose cumulative entitlement became negative on one date.
data BudgetHistoryError
  = BudgetHistoryNegativeEntitlement
      BudgetCycle
      EnvelopeId
      Commodity
      Day
      Quantity
  deriving (Eq, Show)

-- | Admit budget changes as a validated history.
--
-- Changes are evaluated by effective date rather than source order. Changes on
-- the same date are combined before the cumulative entitlement is tested.
mkBudgetHistory
  :: [BudgetChange]
  -> Either (NonEmpty BudgetHistoryError) BudgetHistory
mkBudgetHistory changes =
  case NonEmpty.nonEmpty historyErrors of
    Just errors -> Left errors
    Nothing     -> Right (BudgetHistory changes)
  where
    historyErrors = concatMap validateCoordinate (Map.toAscList histories)
    histories = Map.fromListWith (Map.unionWith addQuantity)
      [ ( coordinate
        , Map.singleton (budgetChangeDate change) (amountQuantity amount)
        )
      | change <- changes
      , let amount = budgetChangeAmount change
      , let coordinate =
              ( budgetChangeCycle change
              , budgetChangeEnvelope change
              , amountCommodity amount
              )
      ]

    validateCoordinate ((cycle, envelope, commodity), datedChanges) =
      case firstNegative datedChanges of
        Nothing -> []
        Just (day, quantity) ->
          [ BudgetHistoryNegativeEntitlement
              cycle
              envelope
              commodity
              day
              quantity
          ]

firstNegative :: Map Day Quantity -> Maybe (Day, Quantity)
firstNegative =
  find ((< zeroQuantity) . snd)
    . snd
    . mapAccumL accumulate zeroQuantity
    . Map.toAscList
  where
    accumulate running (day, delta) =
      let next = addQuantity running delta
      in (next, (day, next))
