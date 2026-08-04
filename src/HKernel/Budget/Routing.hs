-- | Validated routing from Expense accounts into budget distributions.
--
-- Later consumption calculations should depend on this module rather than on
-- the current one-envelope structural lookup in 'HKernel.Budget.Policy'. That
-- keeps future weighted assignment local to one named routing owner.
module HKernel.Budget.Routing
  ( expenseDistributionFor
  ) where

import HKernel.Account (Account)
import HKernel.Budget.Distribution
  ( ExpenseDistribution
  , wholeExpenseDistribution
  )
import HKernel.Budget.Policy
  ( AccountValidatedBudgetPolicy
  , accountValidatedBudgetPolicy
  , budgetPolicyEnvelopeForExpense
  )

-- | Resolve one declared Expense account to its non-empty distribution.
--
-- The initial policy language assigns the whole posting to one envelope, so the
-- result is a singleton distribution with unit weight. A later weighted-policy
-- slice can change only this owner and the policy representation while keeping
-- consumption code dependent on 'ExpenseDistribution'.
expenseDistributionFor
  :: Account
  -> AccountValidatedBudgetPolicy
  -> Maybe ExpenseDistribution
expenseDistributionFor account =
  fmap wholeExpenseDistribution
    . budgetPolicyEnvelopeForExpense account
    . accountValidatedBudgetPolicy
