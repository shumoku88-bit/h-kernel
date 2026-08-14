module HKernel.Envelope.ExpenseRouting
  ( ExpenseRoute(..)
  , ExpenseRoutingDecision(..)
  , ExpenseRoutingHistory
  , ExpenseRoutingHistoryError(..)
  , ExpenseRoutingReferenceError(..)
  , mkExpenseRoutingHistory
  , admitExpenseRoutingReferences
  , expenseRoutingHistoryDecisions
  , expenseRoutingDecisionAt
  , expenseRouteAt
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Time.Calendar (Day)
import HKernel.Account
  ( Account
  , AccountRegistry
  , AccountType(..)
  , declaredAccountType
  , lookupAccountDeclaration
  )
import HKernel.Envelope.Identity
  ( EnvelopeId
  , EnvelopeRegistry
  , envelopeRegistryContains
  )

-- | Current meaning of one Expense account at one historical observation.
--
-- Absence is deliberately not represented here. A missing routing decision is
-- attention evidence; 'NotEnvelopeManaged' is an explicit household decision.
data ExpenseRoute
  = ManagedByEnvelope EnvelopeId
  | NotEnvelopeManaged
  deriving (Eq, Ord, Show)

-- | One effective-dated routing decision.
--
-- The decision is policy history rather than accounting fact. Its effective day
-- lets later configuration changes alter current intent without rewriting how
-- earlier Actual observations were classified.
data ExpenseRoutingDecision = ExpenseRoutingDecision
  { expenseRoutingEffectiveFrom :: Day
  , expenseRoutingAccount       :: Account
  , expenseRoutingRoute         :: ExpenseRoute
  , expenseRoutingNote          :: Text
  } deriving (Eq, Show)

newtype ExpenseRoutingHistory = ExpenseRoutingHistory
  { expenseRoutingHistoryDecisions :: [ExpenseRoutingDecision]
  } deriving (Eq, Show)

data ExpenseRoutingHistoryError
  = DuplicateExpenseRoutingDecision Account Day
  deriving (Eq, Show)

-- | A source-admitted routing decision may still dangle across stable Account
-- or Envelope identity boundaries, or attempt to route a non-Expense Account.
-- Errors retain the historical Account/day coordinate without keeping any
-- private source row.
data ExpenseRoutingReferenceError
  = UnknownExpenseRoutingAccount Account Day
  | ExpenseRoutingAccountNotExpense Account Day AccountType
  | UnknownExpenseRoutingEnvelope Account Day EnvelopeId
  deriving (Eq, Show)

-- | Admit routing decisions while preserving source order as provenance.
--
-- A household day is the routing time granularity. Two decisions for the same
-- Expense account with the same effective day are therefore ambiguous and fail
-- closed, even if their targets happen to be equal.
mkExpenseRoutingHistory
  :: [ExpenseRoutingDecision]
  -> Either (NonEmpty ExpenseRoutingHistoryError) ExpenseRoutingHistory
mkExpenseRoutingHistory decisions =
  case NonEmpty.nonEmpty duplicateErrors of
    Just errors -> Left errors
    Nothing -> Right (ExpenseRoutingHistory decisions)
  where
    grouped :: Map (Account, Day) Int
    grouped = Map.fromListWith (+)
      [ ((expenseRoutingAccount decision, expenseRoutingEffectiveFrom decision), 1)
      | decision <- decisions
      ]
    duplicateErrors =
      [ DuplicateExpenseRoutingDecision account effectiveFrom
      | ((account, effectiveFrom), count) <- Map.toAscList grouped
      , count > 1
      ]

-- | Admit the stable references of an already source-admitted Expense routing
-- history.
--
-- Account existence and accounting type are checked against the admitted
-- AccountRegistry. An explicit 'NotEnvelopeManaged' decision still requires an
-- admitted Expense Account.
--
-- Envelope target existence is checked against the stable EnvelopeRegistry,
-- never against current TOML or current BudgetPolicy membership. Removing an
-- Envelope from current policy cannot retroactively invalidate an earlier
-- Expense routing decision.
--
-- Errors accumulate in source order. If one decision has both an invalid
-- Account reference and an unknown Envelope target, both dangling coordinates
-- remain visible.
admitExpenseRoutingReferences
  :: AccountRegistry
  -> EnvelopeRegistry
  -> ExpenseRoutingHistory
  -> Either (NonEmpty ExpenseRoutingReferenceError) ExpenseRoutingHistory
admitExpenseRoutingReferences accountRegistry envelopeRegistry history =
  case NonEmpty.nonEmpty errors of
    Nothing -> Right history
    Just found -> Left found
  where
    errors = concatMap referenceErrors
      (expenseRoutingHistoryDecisions history)

    referenceErrors decision = accountErrors decision ++ envelopeErrors decision

    accountErrors decision =
      case lookupAccountDeclaration (expenseRoutingAccount decision) accountRegistry of
        Nothing ->
          [ UnknownExpenseRoutingAccount
              (expenseRoutingAccount decision)
              (expenseRoutingEffectiveFrom decision)
          ]
        Just declaration
          | declaredAccountType declaration == Expense -> []
          | otherwise ->
              [ ExpenseRoutingAccountNotExpense
                  (expenseRoutingAccount decision)
                  (expenseRoutingEffectiveFrom decision)
                  (declaredAccountType declaration)
              ]

    envelopeErrors decision = case expenseRoutingRoute decision of
      NotEnvelopeManaged -> []
      ManagedByEnvelope envelope ->
        [ UnknownExpenseRoutingEnvelope
            (expenseRoutingAccount decision)
            (expenseRoutingEffectiveFrom decision)
            envelope
        | not (envelopeRegistryContains envelope envelopeRegistry)
        ]

-- | Latest decision effective on or before the observation day.
--
-- Effective date, not source order, governs meaning. Admission already proves
-- that no two decisions occupy the same account/day coordinate.
expenseRoutingDecisionAt
  :: Day
  -> Account
  -> ExpenseRoutingHistory
  -> Maybe ExpenseRoutingDecision
expenseRoutingDecisionAt observedOn account =
  foldl' laterDecision Nothing
    . filter visible
    . expenseRoutingHistoryDecisions
  where
    visible decision =
      expenseRoutingAccount decision == account
        && expenseRoutingEffectiveFrom decision <= observedOn
    laterDecision Nothing decision = Just decision
    laterDecision (Just current) decision
      | expenseRoutingEffectiveFrom decision
          > expenseRoutingEffectiveFrom current = Just decision
      | otherwise = Just current

-- | Total only after distinguishing missing policy from explicit management.
-- Nothing means no routing decision exists through the observation day.
expenseRouteAt
  :: Day
  -> Account
  -> ExpenseRoutingHistory
  -> Maybe ExpenseRoute
expenseRouteAt observedOn account =
  fmap expenseRoutingRoute . expenseRoutingDecisionAt observedOn account
