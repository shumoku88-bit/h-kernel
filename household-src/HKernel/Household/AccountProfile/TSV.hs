{-# LANGUAGE OverloadedStrings #-}

-- | Admission for the retained @accounts.tsv@ compatibility surface.
--
-- Physical syntax is separated from semantic classification. Each meaningful
-- row first becomes one canonical 'AccountDeclaration' plus the metadata that
-- remains after @role@ and @currency@ are consumed. The retained metadata is
-- then classified by 'HKernel.Household.AccountProfile'.
--
-- Actual Journal parity is a separate named gate: Account identity, accounting
-- type, and default Commodity must agree in both directions before the profiles
-- are admitted to Household composition.
module HKernel.Household.AccountProfile.TSV
  ( AccountProfileTSVError(..)
  , parseRetainedAccountProfiles
  , validateRetainedAccountProfileRegistry
  , admitRetainedAccountProfiles
  ) where

import Data.Either (partitionEithers)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import HKernel.Account
import HKernel.Household.AccountProfile
import HKernel.Money (mkCommodity)

-- | Source-local diagnostic that retains coordinates but never a complete
-- private row.
data AccountProfileTSVError = AccountProfileTSVError
  { accountProfileTSVErrorSource  :: Text
  , accountProfileTSVErrorLine    :: Int
  , accountProfileTSVErrorMessage :: Text
  } deriving (Eq, Show)

data ParsedProfile = ParsedProfile
  { parsedProfileLine  :: Int
  , parsedProfileValue :: RetainedAccountProfile
  } deriving (Eq, Show)

-- | Parse the retained TSV syntax and classify every admitted row.
--
-- Unknown and non-applicable metadata remain visible through
-- 'retainedAccountUnclassifiedMetadata'. Duplicate Account identity is rejected
-- instead of being collapsed by 'Map.fromList'.
parseRetainedAccountProfiles
  :: Text
  -> Either (NonEmpty AccountProfileTSVError)
       (Map Account RetainedAccountProfile)
parseRetainedAccountProfiles input =
  case NonEmpty.nonEmpty allErrors of
    Just errors -> Left errors
    Nothing -> Right (Map.fromList
      [ (profileAccount row, parsedProfileValue row)
      | row <- parsedRows
      ])
  where
    (rowErrorGroups, parsedRows) =
      partitionEithers (map parseRow (meaningfulLines input))
    rowErrors = concatMap NonEmpty.toList rowErrorGroups
    duplicateErrors =
      [ errorAt accountsSource lineNumber
          ("duplicate Account " <> accountName account)
      | (account, lineNumber) <- duplicateCoordinates
          [ (profileAccount row, parsedProfileLine row)
          | row <- parsedRows
          ]
      ]
    allErrors = rowErrors ++ duplicateErrors

-- | Compare retained declarations with the Actual Journal registry.
--
-- The relation is total in both directions. Matching Account identity alone is
-- insufficient: accounting type and default Commodity are independent parts of
-- the declaration and are diagnosed separately.
validateRetainedAccountProfileRegistry
  :: AccountRegistry
  -> Map Account RetainedAccountProfile
  -> Either (NonEmpty AccountProfileTSVError) ()
validateRetainedAccountProfileRegistry actualRegistry profiles =
  case NonEmpty.nonEmpty errors of
    Just values -> Left values
    Nothing -> Right ()
  where
    errors = sourceErrors ++ actualErrors
    sourceErrors = concatMap validateSourceProfile (Map.toAscList profiles)
    actualErrors =
      [ errorAt actualSource 0
          ("actual.journal Account is missing from accounts.tsv: "
            <> accountName account)
      | declaration <- accountDeclarations actualRegistry
      , let account = declaredAccount declaration
      , Map.notMember account profiles
      ]

    validateSourceProfile (account, profile) =
      case lookupAccountDeclaration account actualRegistry of
        Nothing ->
          [ errorAt accountsSource 0
              ("accounts.tsv Account is not declared in actual.journal: "
                <> accountName account)
          ]
        Just actualDeclaration ->
          typeErrors sourceDeclaration actualDeclaration
            ++ commodityErrors sourceDeclaration actualDeclaration
      where
        sourceDeclaration = retainedAccountDeclaration profile

    typeErrors sourceDeclaration actualDeclaration
      | declaredAccountType sourceDeclaration
          == declaredAccountType actualDeclaration = []
      | otherwise =
          [ errorAt accountsSource 0
              ("Account type disagrees between accounts.tsv and actual.journal for "
                <> accountName (declaredAccount sourceDeclaration)
                <> ": accounts.tsv="
                <> tshow (declaredAccountType sourceDeclaration)
                <> ", actual.journal="
                <> tshow (declaredAccountType actualDeclaration))
          ]

    commodityErrors sourceDeclaration actualDeclaration
      | declaredAccountDefaultCommodity sourceDeclaration
          == declaredAccountDefaultCommodity actualDeclaration = []
      | otherwise =
          [ errorAt accountsSource 0
              ("default Commodity disagrees between accounts.tsv and actual.journal for "
                <> accountName (declaredAccount sourceDeclaration)
                <> ": accounts.tsv="
                <> tshow (declaredAccountDefaultCommodity sourceDeclaration)
                <> ", actual.journal="
                <> tshow (declaredAccountDefaultCommodity actualDeclaration))
          ]

-- | Admit retained profiles only when syntax, classification, and Actual
-- Journal declaration parity all succeed.
admitRetainedAccountProfiles
  :: AccountRegistry
  -> Text
  -> Either (NonEmpty AccountProfileTSVError)
       (Map Account RetainedAccountProfile)
admitRetainedAccountProfiles actualRegistry input = do
  profiles <- parseRetainedAccountProfiles input
  validateRetainedAccountProfileRegistry actualRegistry profiles
  Right profiles

parseRow
  :: (Int, Text)
  -> Either (NonEmpty AccountProfileTSVError) ParsedProfile
parseRow (lineNumber, line) = case T.splitOn "\t" line of
  accountText : fields -> do
    account <- mapLeft
      (singleError lineNumber . tshow)
      (mkAccount accountText)
    metadata <- mapLeft NonEmpty.singleton
      (parseMetadata lineNumber fields)
    roleText <- mapLeft NonEmpty.singleton
      (requireField lineNumber "role" metadata)
    role <- mapLeft NonEmpty.singleton
      (parseRole lineNumber roleText)
    currencyText <- mapLeft NonEmpty.singleton
      (requireField lineNumber "currency" metadata)
    commodity <- mapLeft
      (singleError lineNumber . tshow)
      (mkCommodity currencyText)
    let declaration =
          declareAccountWithDefaultCommodity account role commodity
        retainedMetadata =
          Map.delete "currency" (Map.delete "role" metadata)
    profile <- mapLeft
      (fmap (errorAt accountsSource lineNumber . tshow))
      (classifyRetainedAccountProfile declaration retainedMetadata)
    Right ParsedProfile
      { parsedProfileLine = lineNumber
      , parsedProfileValue = profile
      }
  [] -> Left (singleError lineNumber "expected an account row")

parseMetadata
  :: Int
  -> [Text]
  -> Either AccountProfileTSVError (Map Text Text)
parseMetadata lineNumber fields = do
  entries <- traverse parseField fields
  case duplicateKeys fst entries of
    [] -> Right (Map.fromList entries)
    duplicate : _ -> Left (errorAt accountsSource lineNumber
      ("duplicate metadata key " <> duplicate))
  where
    parseField field = case T.breakOn "=" field of
      (key, remainder)
        | not (T.null key)
        , not (T.null remainder)
        , let value = T.drop 1 remainder
        , not (T.null value) -> Right (key, value)
      _ -> Left (errorAt accountsSource lineNumber
        ("malformed metadata field " <> field
          <> "; expected non-empty key=value"))

parseRole :: Int -> Text -> Either AccountProfileTSVError AccountType
parseRole lineNumber role = case T.toCaseFold role of
  "asset" -> Right Asset
  "liability" -> Right Liability
  "equity" -> Right Equity
  "income" -> Right Income
  "expense" -> Right Expense
  "budget" -> Right Budget
  _ -> Left (errorAt accountsSource lineNumber
    ("unsupported role " <> role))

requireField
  :: Int
  -> Text
  -> Map Text Text
  -> Either AccountProfileTSVError Text
requireField lineNumber field metadata =
  maybe
    (Left (errorAt accountsSource lineNumber ("missing " <> field)))
    Right
    (Map.lookup field metadata)

profileAccount :: ParsedProfile -> Account
profileAccount =
  declaredAccount
    . retainedAccountDeclaration
    . parsedProfileValue

meaningfulLines :: Text -> [(Int, Text)]
meaningfulLines =
  filter (not . ignored . snd) . zip [1..] . T.lines
  where
    ignored line =
      let stripped = T.strip line
      in T.null stripped || "#" `T.isPrefixOf` stripped

-- | Return every occurrence after the first for a repeated identity.
duplicateCoordinates :: Ord key => [(key, Int)] -> [(key, Int)]
duplicateCoordinates = reverse . third . foldl observe (Map.empty, [], [])
  where
    observe (seen, unique, repeated) coordinate@(key, _)
      | Map.member key seen = (seen, unique, coordinate : repeated)
      | otherwise = (Map.insert key () seen, coordinate : unique, repeated)
    third (_, _, value) = value

duplicateKeys :: Ord key => (value -> key) -> [value] -> [key]
duplicateKeys keyOf values =
  [ key
  | (key, count) <- Map.toAscList
      (Map.fromListWith (+) [(keyOf value, 1 :: Int) | value <- values])
  , count > 1
  ]

accountsSource :: Text
accountsSource = "accounts.tsv"

actualSource :: Text
actualSource = "actual.journal"

singleError :: Int -> Text -> NonEmpty AccountProfileTSVError
singleError lineNumber message =
  errorAt accountsSource lineNumber message NonEmpty.:| []

errorAt :: Text -> Int -> Text -> AccountProfileTSVError
errorAt = AccountProfileTSVError

mapLeft :: (left -> right) -> Either left value -> Either right value
mapLeft f result = case result of
  Left err -> Left (f err)
  Right value -> Right value

tshow :: Show value => value -> Text
tshow = T.pack . show
