{-# LANGUAGE OverloadedStrings #-}

-- | Account identity and explicitly declared accounting metadata.
--
-- Account names identify ledger positions. 'AccountType' supplies the
-- accounting meaning used by reports; that meaning is never guessed from a
-- textual prefix such as @assets:@.
module HKernel.Account
  ( Account
  , AccountError(..)
  , mkAccount
  , accountName
  , AccountType(..)
  , AccountDeclaration
  , declareAccount
  , declareAccountWithDefaultCommodity
  , declaredAccount
  , declaredAccountType
  , declaredAccountDefaultCommodity
  , AccountRegistry
  , AccountRegistryError(..)
  , emptyAccountRegistry
  , registerAccount
  , lookupAccountDeclaration
  , accountTypeFor
  , accountDeclarations
  ) where

import Data.Char (isControl)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import HKernel.Money (Commodity)

-- | A canonical ledger account name such as @assets:bank:checking@.
newtype Account = Account { accountName :: Text }
  deriving (Eq, Ord, Show)

data AccountError
  = EmptyAccount
  | AccountHasSurroundingWhitespace Text
  | AccountContainsControlCharacter Text
  deriving (Eq, Show)

mkAccount :: Text -> Either AccountError Account
mkAccount name
  | T.null name          = Left EmptyAccount
  | T.strip name /= name = Left (AccountHasSurroundingWhitespace name)
  | T.any isControl name = Left (AccountContainsControlCharacter name)
  | otherwise            = Right (Account name)

-- | The five accounting categories used by the core financial statements.
--
-- Constructors are deliberately small and concrete. More specialised tags can
-- be added later without weakening the meaning of these report categories.
data AccountType
  = Asset
  | Liability
  | Equity
  | Income
  | Expense
  deriving (Eq, Ord, Show)

-- | Metadata attached to one declared account.
--
-- A default commodity is optional: an account without one can still hold
-- several explicitly written commodities. The constructor is hidden so future
-- invariants can be added without changing callers that use the smart
-- constructors below.
data AccountDeclaration = AccountDeclaration
  { declaredAccount                 :: Account
  , declaredAccountType             :: AccountType
  , declaredAccountDefaultCommodity :: Maybe Commodity
  } deriving (Eq, Show)

-- | Declare an account whose postings must state their commodity explicitly.
declareAccount :: Account -> AccountType -> AccountDeclaration
declareAccount account accountType =
  AccountDeclaration account accountType Nothing

-- | Declare an account with one default commodity.
--
-- This function records metadata only. Checking an explicit posting commodity
-- against this default belongs to Journal validation, not to the Account type.
declareAccountWithDefaultCommodity
  :: Account
  -> AccountType
  -> Commodity
  -> AccountDeclaration
declareAccountWithDefaultCommodity account accountType commodity =
  AccountDeclaration account accountType (Just commodity)

-- | Canonical account metadata, indexed by account identity.
newtype AccountRegistry = AccountRegistry (Map Account AccountDeclaration)
  deriving (Eq, Show)

data AccountRegistryError
  = DuplicateAccountDeclaration Account
  deriving (Eq, Show)

emptyAccountRegistry :: AccountRegistry
emptyAccountRegistry = AccountRegistry Map.empty

-- | Add one declaration. Re-declaration is rejected instead of silently
-- replacing earlier metadata.
registerAccount
  :: AccountDeclaration
  -> AccountRegistry
  -> Either AccountRegistryError AccountRegistry
registerAccount declaration (AccountRegistry registry)
  | Map.member account registry = Left (DuplicateAccountDeclaration account)
  | otherwise = Right
      (AccountRegistry (Map.insert account declaration registry))
  where
    account = declaredAccount declaration

lookupAccountDeclaration
  :: Account
  -> AccountRegistry
  -> Maybe AccountDeclaration
lookupAccountDeclaration account (AccountRegistry registry) =
  Map.lookup account registry

accountTypeFor :: Account -> AccountRegistry -> Maybe AccountType
accountTypeFor account registry =
  declaredAccountType <$> lookupAccountDeclaration account registry

accountDeclarations :: AccountRegistry -> [AccountDeclaration]
accountDeclarations (AccountRegistry registry) = Map.elems registry
