-- | Exact actual consumption derived from Journal Expense postings.
--
-- This module owns the first calculation after validated expense routing. It
-- clips accounting facts to one explicit point-in-time budget observation,
-- keeps commodity identity inside 'Balance', and retains unassigned Expense
-- activity as explicit evidence. It deliberately does not apportion one posting
-- across multiple envelopes.
module HKernel.Budget.Consumption
  ( EnvelopeConsumption
  , envelopeConsumptionEnvelope
  , envelopeConsumptionCharges
  , envelopeConsumptionRefunds
  , envelopeConsumptionBalance
  , UnassignedExpenseConsumption
  , unassignedExpenseAccount
  , unassignedExpenseBalance
  , BudgetConsumption
  , budgetConsumptionObservation
  , budgetConsumptionCycle
  , budgetConsumptionObservedThrough
  , budgetConsumptionEnvelopes
  , budgetConsumptionUnassignedExpenses
  , ConsumptionError(..)
  , calculateBudgetConsumption
  ) where

import Data.List.NonEmpty (NonEmpty((:|)))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Time.Calendar (Day)
import HKernel.Account
  ( Account
  , AccountType(..)
  , declaredAccountType
  , lookupAccountDeclaration
  )
import HKernel.Budget
  ( BudgetCycle
  , BudgetObservation
  , EnvelopeId
  , budgetObservationContains
  , budgetObservationCycle
  , budgetObservationObservedThrough
  )
import HKernel.Budget.Distribution
  ( ExpenseDistribution
  , envelopeShareEnvelope
  , expenseDistributionShares
  )
import HKernel.Budget.Policy
  ( AccountValidatedBudgetPolicy
  , BudgetPolicy
  , accountValidatedBudgetPolicy
  , budgetPolicyEnvelopeDefinitions
  , envelopeDefinitionId
  )
import HKernel.Budget.Routing (expenseDistributionFor)
import HKernel.Journal
  ( Journal
  , journalAccountRegistry
  , journalTransactions
  )
import HKernel.Ledger
  ( Posting
  , postingAccount
  , postingAmount
  , transactionDate
  , transactionPostings
  )
import HKernel.Money
  ( Amount
  , Balance
  , addBalance
  , amountQuantity
  , emptyBalance
  , negateAmount
  , singletonBalance
  , subtractBalance
  , zeroQuantity
  )

-- | Exact actual consumption at one envelope coordinate.
--
-- Positive Expense postings are retained as charges, while negative Expense
-- postings are normalized into positive refund evidence. Net consumption remains
-- the exact subtraction of those two independently visible components.
data EnvelopeConsumption = EnvelopeConsumption
  { envelopeConsumptionEnvelope :: EnvelopeId
  , envelopeConsumptionCharges  :: Balance
  , envelopeConsumptionRefunds  :: Balance
  } deriving (Eq, Show)

-- | Exact net consumption after refunds.
envelopeConsumptionBalance :: EnvelopeConsumption -> Balance
envelopeConsumptionBalance consumption =
  envelopeConsumptionCharges consumption
    `subtractBalance` envelopeConsumptionRefunds consumption

-- | Exact Expense activity that policy did not assign to a spendable envelope.
data UnassignedExpenseConsumption = UnassignedExpenseConsumption
  { unassignedExpenseAccount :: Account
  , unassignedExpenseBalance :: Balance
  } deriving (Eq, Show)

-- | Consumption facts for one point-in-time budget observation.
--
-- Every policy envelope is present, including envelopes with canonical zero
-- consumption. Unassigned Expense accounts are present when they had activity,
-- even when their activity nets to canonical zero.
data BudgetConsumption = BudgetConsumption
  { budgetConsumptionObservation       :: BudgetObservation
  , budgetConsumptionEnvelopes          :: [EnvelopeConsumption]
  , budgetConsumptionUnassignedExpenses :: [UnassignedExpenseConsumption]
  } deriving (Eq, Show)

budgetConsumptionCycle :: BudgetConsumption -> BudgetCycle
budgetConsumptionCycle =
  budgetObservationCycle . budgetConsumptionObservation

budgetConsumptionObservedThrough :: BudgetConsumption -> Day
budgetConsumptionObservedThrough =
  budgetObservationObservedThrough . budgetConsumptionObservation

-- | A routed posting cannot be consumed until a later apportionment owner can
-- divide its exact amount among multiple envelope shares.
data ConsumptionError
  = ConsumptionRequiresApportionment Account ExpenseDistribution
  deriving (Eq, Show)

-- | One accounting fact interpreted in the coordinates owned by Consumption.
--
-- This intermediate meaning separates Journal observation and routing from the
-- later coordinate reduction. It is deliberately internal: callers receive the
-- canonical aggregate rather than an execution trace.
data ConsumptionContribution
  = EnvelopeContribution EnvelopeId Amount
  | UnassignedContribution Account Amount

-- | Derive exact envelope consumption through one inclusive observation day.
--
-- The calculation has four semantic stages:
--
-- * observe declared Expense postings visible in the budget observation,
-- * interpret each posting through validated routing,
-- * reduce contributions at envelope or unassigned-account coordinates,
-- * publish every policy envelope, including canonical zero consumption.
--
-- Positive Expense postings increase charges. Negative Expense postings become
-- positive refund evidence and reduce net consumption. The current routing
-- language produces singleton distributions, so one posting is transferred whole
-- to one envelope without rounding.
calculateBudgetConsumption
  :: BudgetObservation
  -> AccountValidatedBudgetPolicy
  -> Journal
  -> Either ConsumptionError BudgetConsumption
calculateBudgetConsumption observation validatedPolicy journal =
  publishBudgetConsumption observation policy
    <$> traverse
      (contributionFor validatedPolicy)
      (expensePostingsInObservation observation journal)
  where
    policy = accountValidatedBudgetPolicy validatedPolicy

expensePostingsInObservation :: BudgetObservation -> Journal -> [Posting]
expensePostingsInObservation observation journal =
  [ posting
  | transaction <- journalTransactions journal
  , budgetObservationContains observation (transactionDate transaction)
  , posting <- NonEmpty.toList (transactionPostings transaction)
  , isExpensePosting posting
  ]
  where
    registry = journalAccountRegistry journal

    isExpensePosting posting =
      case lookupAccountDeclaration (postingAccount posting) registry of
        Just declaration -> declaredAccountType declaration == Expense
        Nothing          -> False

contributionFor
  :: AccountValidatedBudgetPolicy
  -> Posting
  -> Either ConsumptionError ConsumptionContribution
contributionFor validatedPolicy posting =
  case expenseDistributionFor account validatedPolicy of
    Nothing -> Right (UnassignedContribution account amount)
    Just distribution ->
      case expenseDistributionShares distribution of
        share :| [] -> Right
          (EnvelopeContribution (envelopeShareEnvelope share) amount)
        _ -> Left (ConsumptionRequiresApportionment account distribution)
  where
    account = postingAccount posting
    amount = postingAmount posting

publishBudgetConsumption
  :: BudgetObservation
  -> BudgetPolicy
  -> [ConsumptionContribution]
  -> BudgetConsumption
publishBudgetConsumption observation policy contributions = BudgetConsumption
  { budgetConsumptionObservation = observation
  , budgetConsumptionEnvelopes =
      [ EnvelopeConsumption
          { envelopeConsumptionEnvelope = envelope
          , envelopeConsumptionCharges =
              Map.findWithDefault emptyBalance envelope envelopeCharges
          , envelopeConsumptionRefunds =
              Map.findWithDefault emptyBalance envelope envelopeRefunds
          }
      | definition <- budgetPolicyEnvelopeDefinitions policy
      , let envelope = envelopeDefinitionId definition
      ]
  , budgetConsumptionUnassignedExpenses =
      [ UnassignedExpenseConsumption account balance
      | (account, balance) <- Map.toAscList unassignedBalances
      ]
  }
  where
    envelopeAmounts =
      [ (envelope, amount)
      | EnvelopeContribution envelope amount <- contributions
      ]
    envelopeCharges = contributionBalances
      [ (envelope, amount)
      | (envelope, amount) <- envelopeAmounts
      , amountQuantity amount > zeroQuantity
      ]
    envelopeRefunds = contributionBalances
      [ (envelope, negateAmount amount)
      | (envelope, amount) <- envelopeAmounts
      , amountQuantity amount < zeroQuantity
      ]
    unassignedBalances = contributionBalances
      [ (account, amount)
      | UnassignedContribution account amount <- contributions
      ]

contributionBalances :: Ord key => [(key, Amount)] -> Map key Balance
contributionBalances = Map.fromListWith addBalance
  . map (fmap singletonBalance)
