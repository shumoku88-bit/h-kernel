{-# LANGUAGE OverloadedStrings #-}

-- | Deterministic declaration-only shadow conversion for retained Account
-- profiles.
--
-- This module owns one migration projection only. It copies Account identity,
-- accounting type, and optional default Commodity into the strict
-- @accounts.journal@ syntax already admitted by 'parseAccountJournal'. Budget
-- policy, household policy, and unclassified retained metadata remain outside
-- this surface.
module HKernel.Household.AccountProfile.AccountJournalShadow
  ( AccountJournalShadowError(..)
  , projectRetainedAccountDeclarations
  , renderAccountDeclarationsShadow
  , renderRetainedAccountJournalShadow
  , validateRetainedAccountJournalShadow
  ) where

import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import HKernel.Account
  ( Account
  , AccountDeclaration
  , AccountRegistry
  , AccountType(..)
  , accountDeclarations
  , accountName
  , declaredAccount
  , declaredAccountDefaultCommodity
  , declaredAccountType
  )
import HKernel.Account.Journal (parseAccountJournal)
import HKernel.Household.AccountProfile
  ( RetainedAccountProfile
  , retainedAccountDeclaration
  )
import HKernel.Money (commodityCode)

-- | A privacy-preserving failure from rendering and re-admitting one shadow.
--
-- The error identifies only the failed declaration coordinate. It deliberately
-- does not retain Account names, source rows, or rendered Journal text, so the
-- same gate can be used against a private canonical source without publishing
-- its contents through diagnostics.
data AccountJournalShadowError
  = AccountJournalShadowParseRejected Int
  | AccountJournalShadowAccountSetMismatch
  | AccountJournalShadowAccountTypeMismatch
  | AccountJournalShadowDefaultCommodityMismatch
  deriving (Eq, Show)

-- | Project only the declaration coordinates owned by @accounts.journal@.
--
-- Ordering is explicit and source-independent. Neither TSV row order nor the
-- internal ordering of the input 'Map' is treated as migration evidence.
projectRetainedAccountDeclarations
  :: Map Account RetainedAccountProfile
  -> [AccountDeclaration]
projectRetainedAccountDeclarations =
  sortDeclarations
    . map retainedAccountDeclaration
    . Map.elems

-- | Render declarations in canonical Account identity order.
--
-- Every current 'AccountDeclaration' is representable because Account and
-- Commodity smart constructors have already excluded whitespace and control
-- shapes that the Journal syntax cannot carry. The exhaustive AccountType
-- renderer makes a future unhandled category a compile-time failure.
renderAccountDeclarationsShadow :: [AccountDeclaration] -> Text
renderAccountDeclarationsShadow declarations =
  T.intercalate "\n" (map renderDeclaration (sortDeclarations declarations))

-- | Render retained profiles as a deterministic declaration-only Journal.
renderRetainedAccountJournalShadow
  :: Map Account RetainedAccountProfile
  -> Text
renderRetainedAccountJournalShadow =
  renderAccountDeclarationsShadow . projectRetainedAccountDeclarations

-- | Render, parse with the existing strict Account Journal owner, and require
-- exact declaration parity.
--
-- The comparison separates Account identity, AccountType, and default
-- Commodity so a failure can be reported without embedding private values.
validateRetainedAccountJournalShadow
  :: Map Account RetainedAccountProfile
  -> Either (NonEmpty AccountJournalShadowError) ()
validateRetainedAccountJournalShadow profiles =
  case parseAccountJournal rendered of
    Left errors ->
      Left (AccountJournalShadowParseRejected (NonEmpty.length errors)
        NonEmpty.:| [])
    Right registry ->
      case NonEmpty.nonEmpty
          (declarationParityErrors expected (accountDeclarations registry)) of
        Just errors -> Left errors
        Nothing -> Right ()
  where
    expected = projectRetainedAccountDeclarations profiles
    rendered = renderAccountDeclarationsShadow expected

sortDeclarations :: [AccountDeclaration] -> [AccountDeclaration]
sortDeclarations = sortOn (accountName . declaredAccount)

renderDeclaration :: AccountDeclaration -> Text
renderDeclaration declaration = T.unlines
  ( [ "account " <> accountName (declaredAccount declaration)
    , "  type: " <> renderAccountType (declaredAccountType declaration)
    ]
    ++ maybe []
      (pure . ("  commodity: " <>) . commodityCode)
      (declaredAccountDefaultCommodity declaration)
  )

renderAccountType :: AccountType -> Text
renderAccountType accountType = case accountType of
  Asset     -> "Asset"
  Liability -> "Liability"
  Equity    -> "Equity"
  Income    -> "Income"
  Expense   -> "Expense"
  Budget    -> "Budget"

declarationParityErrors
  :: [AccountDeclaration]
  -> [AccountDeclaration]
  -> [AccountJournalShadowError]
declarationParityErrors expected actual
  | expectedAccounts /= actualAccounts =
      [AccountJournalShadowAccountSetMismatch]
  | otherwise =
      [ AccountJournalShadowAccountTypeMismatch
      | map declaredAccountType expected /= map declaredAccountType actual
      ]
      ++ [ AccountJournalShadowDefaultCommodityMismatch
         | map declaredAccountDefaultCommodity expected
             /= map declaredAccountDefaultCommodity actual
         ]
  where
    expectedAccounts = map declaredAccount expected
    actualAccounts = map declaredAccount actual
