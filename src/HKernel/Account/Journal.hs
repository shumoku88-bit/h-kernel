{-# LANGUAGE OverloadedStrings #-}

-- | Strict admission and canonical rendering for an account-declaration
-- Journal source.
--
-- The ordinary Journal parser remains the single owner of account names,
-- accounting types, optional default commodities, duplicate declarations, and
-- source-line diagnostics. This module adds only the source-specific boundary:
-- an @accounts.journal@ may contain account declarations and comments, but no
-- transactions, includes, global commodity directives, or unknown account
-- metadata.
module HKernel.Account.Journal
  ( AccountJournalError(..)
  , AccountDeclarationRenderError(..)
  , parseAccountJournal
  , renderAccountDeclaration
  ) where

import Data.Char (isSpace)
import Data.List (foldl')
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import HKernel.Account
  ( AccountDeclaration
  , AccountRegistry
  , AccountType(..)
  , accountDeclarations
  , accountName
  , declaredAccount
  , declaredAccountDefaultCommodity
  , declaredAccountType
  )
import HKernel.Journal
  ( JournalError
  , journalAccountRegistry
  , parseJournal
  )
import HKernel.Money (commodityCode)

-- | Failure to admit one declaration-only Journal source.
--
-- Ordinary Journal syntax and declaration failures remain wrapped in their
-- original typed error. The additional constructors describe meanings that are
-- valid elsewhere in the Journal family but forbidden in @accounts.journal@.
data AccountJournalError
  = AccountJournalSyntaxError JournalError
  | UnsupportedAccountJournalBlock Int Text
  | UnknownAccountJournalMetadata Int Text
  | MalformedAccountJournalMetadata Int Text
  deriving (Eq, Show)

-- | Privacy-preserving failure to render one declaration with exact parse-back
-- parity. No Account identity or rendered source bytes are retained.
data AccountDeclarationRenderError
  = AccountDeclarationUnrepresentable
  | RenderedAccountDeclarationRejected Int
  | AccountDeclarationRoundTripMismatch
  deriving (Eq, Show)

-- | Parse one strict declaration source into its canonical account registry.
--
-- This function deliberately publishes 'AccountRegistry' rather than an empty
-- transaction Journal. The source-shape gate runs first, then the existing
-- Journal parser owns all account declaration syntax and invariant checks.
parseAccountJournal
  :: Text
  -> Either (NonEmpty AccountJournalError) AccountRegistry
parseAccountJournal input =
  case NonEmpty.nonEmpty (accountJournalShapeErrors input) of
    Just errors -> Left errors
    Nothing -> case parseJournal input of
      Left errors -> Left (fmap AccountJournalSyntaxError errors)
      Right journal -> Right (journalAccountRegistry journal)

-- | Render one Account declaration and prove that the strict declaration
-- parser returns the exact same semantic value.
--
-- Account identity currently permits the Journal comment delimiter. Because
-- the parser treats @;@ as the start of a comment, such an identity cannot be
-- represented without inventing an escaping syntax. It is therefore rejected
-- before source text is published.
renderAccountDeclaration
  :: AccountDeclaration
  -> Either AccountDeclarationRenderError Text
renderAccountDeclaration declaration
  | T.any (== ';') (accountName (declaredAccount declaration)) =
      Left AccountDeclarationUnrepresentable
  | otherwise =
      case parseAccountJournal rendered of
        Left errors ->
          Left (RenderedAccountDeclarationRejected (NonEmpty.length errors))
        Right registry ->
          case accountDeclarations registry of
            [parsed] | parsed == declaration -> Right rendered
            _ -> Left AccountDeclarationRoundTripMismatch
  where
    rendered = T.unlines
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

data AccountBlockState
  = OutsideAccountBlock
  | InsideAccountBlock

accountJournalShapeErrors :: Text -> [AccountJournalError]
accountJournalShapeErrors =
  reverse . snd . foldl' step initial . zip [1..] . T.lines
  where
    initial = (OutsideAccountBlock, [])

    step (state, errors) (lineNumber, line)
      | T.null stripped = (OutsideAccountBlock, errors)
      | isIndented line = case state of
          OutsideAccountBlock -> (state, errors)
          InsideAccountBlock ->
            ( state
            , reverse (metadataErrors lineNumber line) ++ errors
            )
      | isComment line = (state, errors)
      | isDirective "account" line = (InsideAccountBlock, errors)
      | otherwise =
          ( OutsideAccountBlock
          , UnsupportedAccountJournalBlock lineNumber stripped : errors
          )
      where
        stripped = T.strip line

metadataErrors :: Int -> Text -> [AccountJournalError]
metadataErrors lineNumber line =
  case metadataKey line of
    Just key
      | key `elem` supportedMetadataKeys -> []
      | otherwise -> [UnknownAccountJournalMetadata lineNumber key]
    Nothing
      | isComment line -> []
      | otherwise -> [MalformedAccountJournalMetadata lineNumber (T.strip line)]

metadataKey :: Text -> Maybe Text
metadataKey line =
  case T.breakOn ":" cleanLine of
    (_, remainder) | T.null remainder -> Nothing
    (rawKey, _) -> Just (T.toCaseFold (T.strip rawKey))
  where
    cleanLine = T.strip
      (T.dropWhile (\character -> character == ';' || isSpace character)
        (T.strip line))

supportedMetadataKeys :: [Text]
supportedMetadataKeys = ["type", "role", "commodity"]

isDirective :: Text -> Text -> Bool
isDirective keyword line =
  case T.stripPrefix keyword (T.stripStart line) of
    Nothing -> False
    Just remainder ->
      T.null remainder
        || maybe False (isSpace . fst) (T.uncons remainder)

isComment :: Text -> Bool
isComment = T.isPrefixOf ";" . T.stripStart

isIndented :: Text -> Bool
isIndented line = case T.uncons line of
  Just (character, _) -> isSpace character
  Nothing -> False
