module HKernel.Envelope.ExpenseRouting
  ( ExpenseRoute(..)
  , InitialExpenseRoutingDecision(..)
  , ExpenseRoutingDecision(..)
  , ExpenseRoutingHistory
  , ExpenseRoutingHistoryError(..)
  , ExpenseRoutingReferenceError(..)
  , mkExpenseRoutingHistory
  , mkExpenseRoutingHistoryWithInitial
  , admitExpenseRoutingReferences
  , expenseRoutingHistoryInitialDecisions
  , expenseRoutingHistoryDecisions
  , initialExpenseRoutingDecisionFor
  , expenseRoutingDecisionAt
  , expenseRouteAt
  , ExpenseRouteResolver(..)
  , expenseRoutingResolver
  ) where

import Data.List (foldl')
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

-- | Routing evidence that is already effective before the bounded household
-- history being observed.
--
-- This is not an unknown or guessed date. It represents a policy source whose
-- original semantics were timeless/static, or an explicitly declared opening
-- routing state. Later dated decisions may override it without inventing a fake
-- @effective_from@ coordinate for the initial state.
data InitialExpenseRoutingDecision = InitialExpenseRoutingDecision
  { initialExpenseRoutingAccount :: Account
  , initialExpenseRoutingRoute   :: ExpenseRoute
  , initialExpenseRoutingNote    :: Text
  } deriving (Eq, Show)

-- | One effective-dated routing change.
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

data ExpenseRoutingHistory = ExpenseRoutingHistory
  { expenseRoutingHistoryInitialDecisions :: [InitialExpenseRoutingDecision]
  , expenseRoutingHistoryDecisions        :: [ExpenseRoutingDecision]
  } deriving (Eq, Show)

data ExpenseRoutingHistoryError
  = DuplicateInitialExpenseRoutingDecision Account
  | DuplicateExpenseRoutingDecision Account Day
  deriving (Eq, Show)

-- | A source-admitted routing decision may still dangle across stable Account
-- or Envelope identity boundaries, or attempt to route a non-Expense Account.
-- Initial errors deliberately have no day coordinate because inventing one would
-- destroy the distinction this model preserves.
data ExpenseRoutingReferenceError
  = UnknownInitialExpenseRoutingAccount Account
  | InitialExpenseRoutingAccountNotExpense Account AccountType
  | UnknownInitialExpenseRoutingEnvelope Account EnvelopeId
  | UnknownExpenseRoutingAccount Account Day
  | ExpenseRoutingAccountNotExpense Account Day AccountType
  | UnknownExpenseRoutingEnvelope Account Day EnvelopeId
  deriving (Eq, Show)

-- | Backward-compatible constructor for histories containing dated decisions
-- only.
mkExpenseRoutingHistory
  :: [ExpenseRoutingDecision]
  -> Either (NonEmpty ExpenseRoutingHistoryError) ExpenseRoutingHistory
mkExpenseRoutingHistory = mkExpenseRoutingHistoryWithInitial []

-- | Admit opening routing state and effective-dated changes as distinct facts.
--
-- At most one initial decision exists per Expense Account. A household day is
-- the dated routing time granularity, so two dated decisions for the same
-- Account/day are ambiguous and fail closed even if their routes are equal.
-- Source order is preserved independently within the initial and dated evidence
-- streams.
mkExpenseRoutingHistoryWithInitial
  :: [InitialExpenseRoutingDecision]
  -> [ExpenseRoutingDecision]
  -> Either (NonEmpty ExpenseRoutingHistoryError) ExpenseRoutingHistory
mkExpenseRoutingHistoryWithInitial initialDecisions decisions =
  case NonEmpty.nonEmpty duplicateErrors of
    Just errors -> Left errors
    Nothing -> Right ExpenseRoutingHistory
      { expenseRoutingHistoryInitialDecisions = initialDecisions
      , expenseRoutingHistoryDecisions = decisions
      }
  where
    initialGrouped :: Map Account Int
    initialGrouped = Map.fromListWith (+)
      [ (initialExpenseRoutingAccount decision, 1)
      | decision <- initialDecisions
      ]
    datedGrouped :: Map (Account, Day) Int
    datedGrouped = Map.fromListWith (+)
      [ ((expenseRoutingAccount decision, expenseRoutingEffectiveFrom decision), 1)
      | decision <- decisions
      ]
    duplicateInitialErrors =
      [ DuplicateInitialExpenseRoutingDecision account
      | (account, count) <- Map.toAscList initialGrouped
      , count > 1
      ]
    duplicateDatedErrors =
      [ DuplicateExpenseRoutingDecision account effectiveFrom
      | ((account, effectiveFrom), count) <- Map.toAscList datedGrouped
      , count > 1
      ]
    duplicateErrors = duplicateInitialErrors ++ duplicateDatedErrors

-- | Admit stable references without interpreting current configuration as
-- historical truth.
--
-- Account existence/type is checked against the admitted AccountRegistry and
-- managed Envelope targets against the stable EnvelopeRegistry. Initial policy
-- and dated changes are both qualified; initial failures intentionally retain no
-- synthetic date coordinate.
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
    errors =
      concatMap initialReferenceErrors
        (expenseRoutingHistoryInitialDecisions history)
        ++ concatMap datedReferenceErrors
          (expenseRoutingHistoryDecisions history)

    initialReferenceErrors decision =
      initialAccountErrors decision ++ initialEnvelopeErrors decision

    initialAccountErrors decision =
      case lookupAccountDeclaration
          (initialExpenseRoutingAccount decision) accountRegistry of
        Nothing ->
          [ UnknownInitialExpenseRoutingAccount
              (initialExpenseRoutingAccount decision)
          ]
        Just declaration
          | declaredAccountType declaration == Expense -> []
          | otherwise ->
              [ InitialExpenseRoutingAccountNotExpense
                  (initialExpenseRoutingAccount decision)
                  (declaredAccountType declaration)
              ]

    initialEnvelopeErrors decision = case initialExpenseRoutingRoute decision of
      NotEnvelopeManaged -> []
      ManagedByEnvelope envelope ->
        [ UnknownInitialExpenseRoutingEnvelope
            (initialExpenseRoutingAccount decision)
            envelope
        | not (envelopeRegistryContains envelope envelopeRegistry)
        ]

    datedReferenceErrors decision =
      datedAccountErrors decision ++ datedEnvelopeErrors decision

    datedAccountErrors decision =
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

    datedEnvelopeErrors decision = case expenseRoutingRoute decision of
      NotEnvelopeManaged -> []
      ManagedByEnvelope envelope ->
        [ UnknownExpenseRoutingEnvelope
            (expenseRoutingAccount decision)
            (expenseRoutingEffectiveFrom decision)
            envelope
        | not (envelopeRegistryContains envelope envelopeRegistry)
        ]

-- | Opening routing evidence for one Account, if declared.
initialExpenseRoutingDecisionFor
  :: Account
  -> ExpenseRoutingHistory
  -> Maybe InitialExpenseRoutingDecision
initialExpenseRoutingDecisionFor account =
  foldl' choose Nothing
    . filter ((== account) . initialExpenseRoutingAccount)
    . expenseRoutingHistoryInitialDecisions
  where
    choose Nothing decision = Just decision
    choose current _ = current

-- | Latest dated decision effective on or before the observation day.
--
-- This query intentionally returns only effective-dated evidence. Use
-- 'expenseRouteAt' for resolved semantics including an initial route.
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

-- | Resolve routing semantics without fabricating a beginning date.
--
-- The latest dated decision visible on the observation day wins. When no dated
-- decision is visible, an initial decision supplies the opening route. Nothing
-- means neither kind of routing evidence exists through the observation day.
expenseRouteAt
  :: Day
  -> Account
  -> ExpenseRoutingHistory
  -> Maybe ExpenseRoute
expenseRouteAt observedOn account history =
  case expenseRoutingDecisionAt observedOn account history of
    Just decision -> Just (expenseRoutingRoute decision)
    Nothing -> initialExpenseRoutingRoute
      <$> initialExpenseRoutingDecisionFor account history

-- | Semantic query boundary for resolving an Expense Account route at one
-- observation date.
newtype ExpenseRouteResolver = ExpenseRouteResolver
  { resolveExpenseRoute :: Day -> Account -> Maybe ExpenseRoute
  }

-- | Project historical routing evidence into semantic query semantics.
expenseRoutingResolver
  :: ExpenseRoutingHistory
  -> ExpenseRouteResolver
expenseRoutingResolver history =
  ExpenseRouteResolver (\day account -> expenseRouteAt day account history)
