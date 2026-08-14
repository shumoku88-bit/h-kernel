{-# LANGUAGE OverloadedStrings #-}

-- | Historical Envelope identity and Expense-routing admission from the shared
-- canonical @household.toml@ source.
--
-- Current Household policy and historical relations intentionally have separate
-- semantic owners even though they share one physical TOML file. This prevents
-- the latest display/calculation policy from becoming retrospective identity or
-- routing truth.
module HKernel.Household.EnvelopeHistory
  ( HouseholdEnvelopeHistory(..)
  , HouseholdEnvelopeHistoryReferenceError(..)
  , parseHouseholdEnvelopeHistory
  , admitHouseholdEnvelopeHistoryReferences
  ) where

import Data.Either (partitionEithers)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import HKernel.Account
  ( Account
  , AccountError
  , AccountRegistry
  , mkAccount
  )
import HKernel.Budget.Policy
  ( BudgetPolicy
  , budgetPolicyEnvelopeDefinitions
  , envelopeDefinitionId
  )
import HKernel.Envelope.ExpenseRouting
  ( ExpenseRoute(..)
  , ExpenseRoutingDecision(..)
  , ExpenseRoutingHistory
  , ExpenseRoutingHistoryError(..)
  , ExpenseRoutingReferenceError
  , admitExpenseRoutingReferences
  , mkExpenseRoutingHistory
  )
import HKernel.Envelope.Identity
  ( EnvelopeId
  , EnvelopeIdError
  , EnvelopeRegistry
  , EnvelopeRegistryError(..)
  , envelopeRegistryContains
  , mkEnvelopeId
  , mkEnvelopeRegistry
  )
import Toml (Value, decode)
import Toml.Schema
  ( FromValue(..)
  , Result(..)
  , optKey
  , parseTableFromValue
  , reqKey
  )

-- | Stable historical Envelope coordinates admitted from the Household source.
--
-- The registry is independent from current policy. Expense routing is
-- effective-dated policy history whose targets are validated against that stable
-- registry and whose Accounts are validated against the canonical AccountRegistry.
data HouseholdEnvelopeHistory = HouseholdEnvelopeHistory
  { householdEnvelopeRegistry       :: EnvelopeRegistry
  , householdExpenseRoutingHistory  :: ExpenseRoutingHistory
  } deriving (Eq, Show)

-- | Cross-source reference failures after TOML syntax admission.
data HouseholdEnvelopeHistoryReferenceError
  = CurrentPolicyEnvelopeMissingFromRegistry EnvelopeId
  | HouseholdExpenseRoutingReferenceError ExpenseRoutingReferenceError
  deriving (Eq, Show)

-- The historical owner shares household.toml with current policy. Pass-through
-- values consume the current-policy sections without duplicating their schema;
-- HKernel.Household.Config remains their strict owner.
data RawHouseholdEnvelopeRoot = RawHouseholdEnvelopeRoot
  Value
  Value
  (Maybe Value)
  (Maybe Value)
  (Maybe Value)
  (Maybe RawEnvelopeHistory)

data RawEnvelopeHistory = RawEnvelopeHistory [Text] [RawExpenseRoutingDecision]

data RawExpenseRoutingDecision = RawExpenseRoutingDecision
  Text
  Text
  Text
  (Maybe Text)
  Text

instance FromValue RawHouseholdEnvelopeRoot where
  fromValue = parseTableFromValue
    (RawHouseholdEnvelopeRoot
      <$> reqKey "cycle"
      <*> reqKey "budget"
      <*> optKey "money"
      <*> optKey "daily-target"
      <*> optKey "account-policy"
      <*> optKey "envelope-history")

instance FromValue RawEnvelopeHistory where
  fromValue = parseTableFromValue
    (RawEnvelopeHistory
      <$> reqKey "identities"
      <*> reqKey "expense-routing")

instance FromValue RawExpenseRoutingDecision where
  fromValue = parseTableFromValue
    (RawExpenseRoutingDecision
      <$> reqKey "effective-from"
      <*> reqKey "expense-account"
      <*> reqKey "route"
      <*> optKey "target"
      <*> reqKey "note")

-- | Parse only the historical Envelope coordinates from canonical household.toml.
--
-- Absence is preserved as 'Nothing' during migration. Canonical Application can
-- therefore observe and qualify the new source before it becomes mandatory for
-- production routing; absence never falls back to current TOML as historical
-- truth.
parseHouseholdEnvelopeHistory
  :: Text
  -> Either [Text] (Maybe HouseholdEnvelopeHistory)
parseHouseholdEnvelopeHistory input =
  case decode input :: Result String RawHouseholdEnvelopeRoot of
    Failure errors -> Left (map T.pack errors)
    Success warnings raw
      | null warnings -> rawToEnvelopeHistory raw
      | otherwise -> Left (map T.pack warnings)

rawToEnvelopeHistory
  :: RawHouseholdEnvelopeRoot
  -> Either [Text] (Maybe HouseholdEnvelopeHistory)
rawToEnvelopeHistory
    (RawHouseholdEnvelopeRoot _ _ _ _ _ maybeRawHistory) =
  traverse parseRawEnvelopeHistory maybeRawHistory

parseRawEnvelopeHistory
  :: RawEnvelopeHistory
  -> Either [Text] HouseholdEnvelopeHistory
parseRawEnvelopeHistory (RawEnvelopeHistory rawIdentities rawDecisions) = do
  identities <- collect
    (zipWith parseIdentity [0 :: Int ..] rawIdentities)
  decisions <- collect
    (zipWith parseDecision [0 :: Int ..] rawDecisions)
  registry <- case mkEnvelopeRegistry identities of
    Right value -> Right value
    Left errors -> Left (map renderRegistryError (NonEmpty.toList errors))
  routing <- case mkExpenseRoutingHistory decisions of
    Right value -> Right value
    Left errors -> Left (map renderRoutingHistoryError (NonEmpty.toList errors))
  Right HouseholdEnvelopeHistory
    { householdEnvelopeRegistry = registry
    , householdExpenseRoutingHistory = routing
    }

parseIdentity :: Int -> Text -> Either [Text] EnvelopeId
parseIdentity index raw =
  case mkEnvelopeId raw of
    Right value -> Right value
    Left err -> Left
      [ path <> ": invalid EnvelopeId: " <> tshow err ]
  where
    path = indexed "envelope-history.identities" index

parseDecision :: Int -> RawExpenseRoutingDecision -> Either [Text] ExpenseRoutingDecision
parseDecision index
    (RawExpenseRoutingDecision rawDate rawAccount rawRoute rawTarget note) =
  case (dateResult, accountResult, routeResult) of
    (Right effectiveFrom, Right account, Right route) -> Right
      ExpenseRoutingDecision
        { expenseRoutingEffectiveFrom = effectiveFrom
        , expenseRoutingAccount = account
        , expenseRoutingRoute = route
        , expenseRoutingNote = note
        }
    _ -> Left
      ( either pure (const []) dateResult
          ++ either pure (const []) accountResult
          ++ either pure (const []) routeResult
      )
  where
    path = indexed "envelope-history.expense-routing" index
    dateResult = parseDate (path <> ".effective-from") rawDate
    accountResult = case mkAccount rawAccount of
      Right account -> Right account
      Left err -> Left
        (path <> ".expense-account: invalid Account: " <> tshow err)
    routeResult = parseRoute path rawRoute rawTarget

parseDate :: Text -> Text -> Either Text Day
parseDate path raw =
  case parseTimeM True defaultTimeLocale "%F" (T.unpack raw) :: Maybe Day of
    Just day -> Right day
    Nothing -> Left (path <> ": invalid ISO date " <> quoted raw)

parseRoute :: Text -> Text -> Maybe Text -> Either Text ExpenseRoute
parseRoute path rawRoute rawTarget = case (rawRoute, rawTarget) of
  ("managed", Just target) ->
    case mkEnvelopeId target of
      Right envelope -> Right (ManagedByEnvelope envelope)
      Left err -> Left
        (path <> ".target: invalid EnvelopeId: " <> tshow err)
  ("managed", Nothing) -> Left
    (path <> ".target: managed routing requires a target EnvelopeId")
  ("unmanaged", Nothing) -> Right NotEnvelopeManaged
  ("unmanaged", Just _) -> Left
    (path <> ".target: unmanaged routing must not declare a target")
  _ -> Left
    (path <> ".route: expected managed or unmanaged; got " <> quoted rawRoute)

-- | Cross-source qualification for an already parsed historical source.
--
-- Every current policy Envelope must belong to the stable registry, but the
-- registry may also retain identities no longer present in current policy.
-- Historical Expense routing references are then admitted against canonical
-- Accounts and the same stable registry, never by replaying current policy.
admitHouseholdEnvelopeHistoryReferences
  :: AccountRegistry
  -> BudgetPolicy
  -> HouseholdEnvelopeHistory
  -> Either (NonEmpty HouseholdEnvelopeHistoryReferenceError) HouseholdEnvelopeHistory
admitHouseholdEnvelopeHistoryReferences accountRegistry budgetPolicy history =
  case NonEmpty.nonEmpty errors of
    Nothing -> Right history
    Just found -> Left found
  where
    registry = householdEnvelopeRegistry history
    currentPolicyErrors =
      [ CurrentPolicyEnvelopeMissingFromRegistry envelope
      | definition <- budgetPolicyEnvelopeDefinitions budgetPolicy
      , let envelope = envelopeDefinitionId definition
      , not (envelopeRegistryContains envelope registry)
      ]
    routingErrors = case admitExpenseRoutingReferences
        accountRegistry
        registry
        (householdExpenseRoutingHistory history) of
      Right _ -> []
      Left found ->
        map HouseholdExpenseRoutingReferenceError (NonEmpty.toList found)
    errors = currentPolicyErrors ++ routingErrors

collect :: [Either [Text] value] -> Either [Text] [value]
collect values = case partitionEithers values of
  ([], parsed) -> Right parsed
  (errors, _) -> Left (concat errors)

renderRegistryError :: EnvelopeRegistryError -> Text
renderRegistryError err = case err of
  DuplicateEnvelopeRegistryIdentity envelope ->
    "envelope-history.identities: duplicate EnvelopeId " <> tshow envelope

renderRoutingHistoryError :: ExpenseRoutingHistoryError -> Text
renderRoutingHistoryError err = case err of
  DuplicateExpenseRoutingDecision account effectiveFrom ->
    "envelope-history.expense-routing: duplicate Account/day coordinate "
      <> tshow account <> " / " <> T.pack (show effectiveFrom)

indexed :: Text -> Int -> Text
indexed path index = path <> "[" <> T.pack (show index) <> "]"

quoted :: Text -> Text
quoted value = "‘" <> value <> "’"

tshow :: Show value => value -> Text
tshow = T.pack . show
