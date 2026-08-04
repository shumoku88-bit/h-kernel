-- | Source-independent household Budget movement fact.
--
-- Current TSV admission may construct this value, but Backing and other
-- household calculations do not depend on the physical source row shape.
module HKernel.Household.BudgetMovement
  ( HouseholdBudgetMovement(..)
  , householdBudgetMovement
  ) where

import Data.Text (Text)
import Data.Time.Calendar (Day)
import HKernel.Account (Account)
import HKernel.Money (Amount)

-- | One exact movement between two household Budget Accounts.
--
-- Source order and memo are retained as evidence. Interpretation belongs to the
-- calculation that receives the movement together with validated policy.
data HouseholdBudgetMovement = HouseholdBudgetMovement
  { householdBudgetMovementDate   :: Day
  , householdBudgetMovementMemo   :: Text
  , householdBudgetMovementFrom   :: Account
  , householdBudgetMovementTo     :: Account
  , householdBudgetMovementAmount :: Amount
  } deriving (Eq, Show)

householdBudgetMovement
  :: Day
  -> Text
  -> Account
  -> Account
  -> Amount
  -> HouseholdBudgetMovement
householdBudgetMovement = HouseholdBudgetMovement
