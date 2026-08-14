{-# LANGUAGE OverloadedStrings #-}

-- | Historical Envelope identity and Expense-routing admission from the shared
-- canonical @household.toml@ source.
--
-- Current Household policy and historical relations intentionally have separate
-- semantic owners even though they share one physical TOML file. This prevents
-- the latest calculation/display configuration from becoming retrospective
-- identity or routing truth.
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
  ( AccountRegistry
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
  , InitialExpenseRoutingDecision(..)
  , admitExpenseRoutingReferences
  , mkExpenseRoutingHistoryWithInitial
  )
import HKernel.Envelope.Identity
  ( EnvelopeId
  , EnvelopeRegistry
  , EnvelopeRegistryError(..)
  , envelopeIdText
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

-- | Stable identity plus historical routing evidence from canonical Household
-- policy storage.
data HouseholdEnvelopeHistory = HouseholdEnvelopeHistory
  { householdEnvelopeRegistry      :: EnvelopeRegistry
  , householdExpenseRoutingHistory :: ExpenseRoutingHistory
  } deriving (Eq, Show)

data HouseholdEnvelopeHistoryReferenceError
  = CurrentPolicyEnvelopeMissingFromRegistry EnvelopeId
  | HouseholdExpenseRoutingReferenceError ExpenseRoutingReferenceError
  deriving (Eq, Show)

-- | Consume the current-policy sections as opaque values. Their schema remains
-- owned by 'HKernel.Household.Config'; this module types only envelope-history.
data RawSharedHouseholdRoot = RawSharedHouseholdRoot
  Value
  Value
  (Maybe Value)
  (Maybe Value)
  (Maybe Value)
  (Maybe RawEnvelopeHistory)

data RawEnvelopeHistory = RawEnvelopeHistory
  [Text]
  [RawExpenseRoutingDecision]

data RawExpenseRoutingDecision = RawExpenseRoutingDecision
  Text
  Text
  Text
  (Maybe Text)
  Text

data ParsedExpenseRoutingDecision
  = ParsedInitial InitialExpenseRoutingDecision
  | ParsedDated ExpenseRoutingDecision

instance FromValue RawSharedHouseholdRoot where
  fromValue = parseTableFromValue
    (RawSharedHouseholdRoot
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

-- | Parse the historical section of canonical household.toml.
--
-- Absence is explicit during migration and never means "derive history from the
-- current BudgetPolicy". @effective-from = "initial"@ represents a policy that
-- is already in force before bounded journal history; ISO dates represent later
-- changes.
parseHouseholdEnvelopeHistory
  :: Text
  -> Either [Text] (Maybe HouseholdEnvelopeHistory)
parseHouseholdEnvelopeHistory input =
  case decode input :: Result String RawSharedHouseholdRoot of
    Failure errors -> Left (map T.pack errors)
    Success warnings raw
      | null warnings -> rawToEnvelopeHistory raw
      | otherwise -> Left (map T.pack warnings)

rawToEnvelopeHistory
  :: RawSharedHouseholdRoot
  -> Either [Text] (Maybe HouseholdEnvelopeHistory)
rawToEnvelopeHistory
    (RawSharedHouseholdRoot _ _ _ _ _ maybeRawHistory) =
  traverse parseRawEnvelopeHistory maybeRawHistory

parseRawEnvelopeHistory
  :: RawEnvelopeHistory
  -> Either [Text] HouseholdEnvelopeHistory
parseRawEnvelopeHistory (RawEnvelopeHistory rawIdentities rawDecisions) = do
  identities <- collect
    (zipWith parseIdentity [0 :: Int ..] rawIdentities)
  parsedDecisions <- collect
    (zipWith parseDecision [0 :: Int ..] rawDecisions)
  registry <- case mkEnvelopeRegistry identities of
    Right value -> Right value
    Left errors -> Left
      (map renderRegistryError (NonEmpty.toList errors))
  routing <- case mkExpenseRoutingHistoryWithInitial
      [decision | ParsedInitial decision <- parsedDecisions]
      [decision | ParsedDated decision <- parsedDecisions] of
    Right value -> Right value
    Left errors -> Left
      (map renderRoutingHistoryError (NonEmpty.toList errors))
  Right HouseholdEnvelopeHistory
    { householdEnvelopeRegistry = registry
    , householdExpenseRoutingHistory = routing
    }

parseIdentity :: Int -> Text -> Either [Text] EnvelopeId
parseIdentity index raw =
  case mkEnvelopeId raw of
    Right value -> Right value
    Left err -> Left
      [ indexed "envelope-history.identities" index
          <> ": invalid EnvelopeId: " <> tshow err
      ]

parseDecision
  :: Int
  -> RawExpenseRoutingDecision
  -> Either [Text] ParsedExpenseRoutingDecision
parseDecision index
    (RawExpenseRoutingDecision rawEffective rawAccount rawRoute rawTarget note) =
  case (accountResult, routeResult) of
    (Right account, Right route)
      | rawEffective == "initial" -> Right
          (ParsedInitial InitialExpenseRoutingDecision
            { initialExpenseRoutingAccount = account
            , initialExpenseRoutingRoute = route
            , initialExpenseRoutingNote = note
            })
      | otherwise -> case parseDate effectivePath rawEffective of
          Right effectiveFrom -> Right
            (ParsedDated ExpenseRoutingDecision
              { expenseRoutingEffectiveFrom = effectiveFrom
              , expenseRoutingAccount = account
              , expenseRoutingRoute = route
              , expenseRoutingNote = note
              })
          Left err -> Left [err]
    _ -> Left
      ( either pure (const []) accountResult
          ++ either pure (const []) routeResult
      )
  where
    path = indexed "envelope-history.expense-routing" index
    effectivePath = path <> ".effective-from"
    accountResult = case mkAccount rawAccount of
      Right account -> Right account
      Left err -> Left
        (path <> ".expense-account: invalid Account: " <> tshow err)
    routeResult = parseRoute path rawRoute rawTarget

parseDate :: Text -> Text -> Either Text Day
parseDate path raw =
  case parseTimeM True defaultTimeLocale "%F" (T.unpack raw) :: Maybe Day of
    Just day -> Right day
    Nothing -> Left
      (path <> ": expected ‘initial’ or ISO date; got " <> quoted raw)

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

-- | Qualify stable references without using current routing maps as historical
-- truth.
--
-- Every current BudgetPolicy Envelope must belong to the stable registry, while
-- the registry may retain identities that are no longer in current policy.
-- Expense routing is checked against canonical Accounts plus that stable
-- registry.
admitHouseholdEnvelopeHistoryReferences
  :: AccountRegistry
  -> BudgetPolicy
  -> HouseholdEnvelopeHistory
  -> Either
      (NonEmpty HouseholdEnvelopeHistoryReferenceError)
      HouseholdEnvelopeHistory
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
        accountRegistry registry (householdExpenseRoutingHistory history) of
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
    "envelope-history.identities: duplicate EnvelopeId "
      <> quoted (envelopeIdText envelope)

renderRoutingHistoryError :: ExpenseRoutingHistoryError -> Text
renderRoutingHistoryError err = case err of
  DuplicateInitialExpenseRoutingDecision account ->
    "envelope-history.expense-routing: duplicate initial Account coordinate "
      <> tshow account
  DuplicateExpenseRoutingDecision account effectiveFrom ->
    "envelope-history.expense-routing: duplicate Account/day coordinate "
      <> tshow account <> " / " <> T.pack (show effectiveFrom)

indexed :: Text -> Int -> Text
indexed path index = path <> "[" <> T.pack (show index) <> "]"

quoted :: Text -> Text
quoted value = "‘" <> value <> "’"

tshow :: Show value => value -> Text
tshow = T.pack . show
