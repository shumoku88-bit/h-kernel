-- | Shared typed flow coordinates and aggregation for accounting reports.
--
-- This module owns Income and Expense classification, sign normalization,
-- period selection, and exact Account x Time aggregation. Named report models
-- remain projections of this shared basis in 'HKernel.Report'.
module HKernel.Report.Flow
  ( DailyFlowPeriod(..)
  , YearMonth
  , yearMonthYear
  , yearMonthNumber
  , yearMonthOf
  , FlowAmounts(..)
  , FlowBasis(..)
  , prepareFlowBasisFor
  ) where

import qualified Data.Map.Strict as Map
import Data.Time.Calendar (Day, toGregorian)
import HKernel.Account
import HKernel.Engine
  ( DateRange
  , LedgerEntry(..)
  , rangeEnd
  , rangeStart
  )
import HKernel.Engine.Facts
  ( AccountingFacts
  , entriesThroughFacts
  )
import HKernel.Money
import HKernel.Report.Matrix

-- | The calculation scope requested for Daily Flow.
data DailyFlowPeriod
  = DailyFlowInRange DateRange
  | DailyFlowThrough Day
  deriving (Eq, Show)

-- | A calendar month obtained from a valid 'Day'.
data YearMonth = YearMonth Integer Int
  deriving (Eq, Ord, Show)

yearMonthYear :: YearMonth -> Integer
yearMonthYear (YearMonth year _) = year

yearMonthNumber :: YearMonth -> Int
yearMonthNumber (YearMonth _ month) = month

yearMonthOf :: Day -> YearMonth
yearMonthOf day = YearMonth year month
  where
    (year, month, _) = toGregorian day

-- | Income and Expense contributions at one daily coordinate.
data FlowAmounts = FlowAmounts
  { flowIncome   :: Balance
  , flowExpenses :: Balance
  }

instance Semigroup FlowAmounts where
  (<>) = addFlowAmounts

instance Monoid FlowAmounts where
  mempty = emptyFlowAmounts

-- | Shared flow facts for independently configured daily and monthly periods.
--
-- The evidence parameter lets the report owner attach its own typed
-- unclassified evidence without making this aggregation module depend on a
-- particular public report row type.
data FlowBasis evidence = FlowBasis
  { flowBasisDailyPeriod         :: DailyFlowPeriod
  , flowBasisMonthlyRange        :: DateRange
  , flowBasisDaily               :: Map.Map Day FlowAmounts
  , flowBasisDailyExpenses       :: BalanceMatrix Account Day
  , flowBasisMonthlyIncome       :: BalanceMatrix Account YearMonth
  , flowBasisMonthlyExpenses     :: BalanceMatrix Account YearMonth
  , flowBasisDailyUnclassified   :: evidence
  , flowBasisMonthlyUnclassified :: evidence
  }

data FlowBuckets = FlowBuckets
  { bucketsByDay           :: Map.Map Day FlowAmounts
  , bucketsDailyExpenses   :: BalanceMatrix Account Day
  , bucketsMonthlyIncome   :: BalanceMatrix Account YearMonth
  , bucketsMonthlyExpenses :: BalanceMatrix Account YearMonth
  }

instance Semigroup FlowBuckets where
  left <> right = FlowBuckets
    { bucketsByDay = Map.unionWith (<>)
        (bucketsByDay left)
        (bucketsByDay right)
    , bucketsDailyExpenses =
        bucketsDailyExpenses left <> bucketsDailyExpenses right
    , bucketsMonthlyIncome =
        bucketsMonthlyIncome left <> bucketsMonthlyIncome right
    , bucketsMonthlyExpenses =
        bucketsMonthlyExpenses left <> bucketsMonthlyExpenses right
    }

instance Monoid FlowBuckets where
  mempty = emptyFlowBuckets

data FlowPlan = FlowPlan
  { flowPlanDailyPeriod  :: DailyFlowPeriod
  , flowPlanMonthlyRange :: DateRange
  }

-- | Prepare the shared flow basis in one fold over canonical entries.
prepareFlowBasisFor
  :: DailyFlowPeriod
  -> DateRange
  -> evidence
  -> evidence
  -> AccountRegistry
  -> AccountingFacts
  -> FlowBasis evidence
prepareFlowBasisFor dailyPeriod monthlyRange dailyUnclassified monthlyUnclassified registry facts = FlowBasis
  { flowBasisDailyPeriod = dailyPeriod
  , flowBasisMonthlyRange = monthlyRange
  , flowBasisDaily = bucketsByDay buckets
  , flowBasisDailyExpenses = bucketsDailyExpenses buckets
  , flowBasisMonthlyIncome = bucketsMonthlyIncome buckets
  , flowBasisMonthlyExpenses = bucketsMonthlyExpenses buckets
  , flowBasisDailyUnclassified = dailyUnclassified
  , flowBasisMonthlyUnclassified = monthlyUnclassified
  }
  where
    plan = FlowPlan dailyPeriod monthlyRange
    buckets = foldMap
      (flowEntryContribution plan registry)
      (entriesThroughFacts (flowPlanEnd plan) facts)

emptyFlowBuckets :: FlowBuckets
emptyFlowBuckets = FlowBuckets
  { bucketsByDay = Map.empty
  , bucketsDailyExpenses = emptyBalanceMatrix
  , bucketsMonthlyIncome = emptyBalanceMatrix
  , bucketsMonthlyExpenses = emptyBalanceMatrix
  }

flowEntryContribution
  :: FlowPlan
  -> AccountRegistry
  -> LedgerEntry
  -> FlowBuckets
flowEntryContribution plan registry entry =
  case accountTypeFor account registry of
    Just Income -> incomeFlowContribution
      plan account day (negateBalance amount)
    Just Expense -> expenseFlowContribution plan account day amount
    _ -> mempty
  where
    account = entryAccount entry
    day = entryDate entry
    amount = singletonBalance (entryAmount entry)

incomeFlowContribution
  :: FlowPlan
  -> Account
  -> Day
  -> Balance
  -> FlowBuckets
incomeFlowContribution plan account day income = FlowBuckets
  { bucketsByDay = flowAmountsWhen
      inDailyPeriod day incomeAmounts
  , bucketsDailyExpenses = emptyBalanceMatrix
  , bucketsMonthlyIncome = balanceCoordinateWhen
      inMonthlyRange account month income
  , bucketsMonthlyExpenses = emptyBalanceMatrix
  }
  where
    inDailyPeriod = dayInDailyPeriod day (flowPlanDailyPeriod plan)
    inMonthlyRange = dayInRange day (flowPlanMonthlyRange plan)
    month = yearMonthOf day
    incomeAmounts = emptyFlowAmounts { flowIncome = income }

expenseFlowContribution
  :: FlowPlan
  -> Account
  -> Day
  -> Balance
  -> FlowBuckets
expenseFlowContribution plan account day expense = FlowBuckets
  { bucketsByDay = flowAmountsWhen
      inDailyPeriod day expenseAmounts
  , bucketsDailyExpenses = balanceCoordinateWhen
      inDailyPeriod account day expense
  , bucketsMonthlyIncome = emptyBalanceMatrix
  , bucketsMonthlyExpenses = balanceCoordinateWhen
      inMonthlyRange account month expense
  }
  where
    inDailyPeriod = dayInDailyPeriod day (flowPlanDailyPeriod plan)
    inMonthlyRange = dayInRange day (flowPlanMonthlyRange plan)
    month = yearMonthOf day
    expenseAmounts = emptyFlowAmounts { flowExpenses = expense }

flowPlanEnd :: FlowPlan -> Day
flowPlanEnd plan = max dailyEnd (rangeEnd (flowPlanMonthlyRange plan))
  where
    dailyEnd = case flowPlanDailyPeriod plan of
      DailyFlowInRange dateRange -> rangeEnd dateRange
      DailyFlowThrough day -> day

dayInDailyPeriod :: Day -> DailyFlowPeriod -> Bool
dayInDailyPeriod day period = case period of
  DailyFlowInRange dateRange -> dayInRange day dateRange
  DailyFlowThrough end -> day <= end

dayInRange :: Day -> DateRange -> Bool
dayInRange day dateRange =
  day >= rangeStart dateRange && day <= rangeEnd dateRange

flowAmountsWhen
  :: Bool
  -> key
  -> FlowAmounts
  -> Map.Map key FlowAmounts
flowAmountsWhen include key amounts
  | include = Map.singleton key amounts
  | otherwise = Map.empty

balanceCoordinateWhen
  :: Bool
  -> row
  -> column
  -> Balance
  -> BalanceMatrix row column
balanceCoordinateWhen include row column amount
  | include = singletonBalanceMatrix row column amount
  | otherwise = emptyBalanceMatrix

addFlowAmounts :: FlowAmounts -> FlowAmounts -> FlowAmounts
addFlowAmounts left right = FlowAmounts
  { flowIncome = addBalance (flowIncome left) (flowIncome right)
  , flowExpenses = addBalance (flowExpenses left) (flowExpenses right)
  }

emptyFlowAmounts :: FlowAmounts
emptyFlowAmounts = FlowAmounts
  { flowIncome = emptyBalance
  , flowExpenses = emptyBalance
  }
