{-# LANGUAGE OverloadedStrings #-}

-- | Admission for the retained @accounts.tsv@ compatibility surface.
--
-- Physical syntax is separated from semantic classification. Each meaningful
-- row first becomes one canonical 'AccountDeclaration' plus the metadata that
-- remains after @role@ and @currency@ are consumed. The retained metadata is
-- then classified by 'HKernel.Household.AccountProfile'.
--
-- Actual Journal parity is a separate named gate. Account identity and
-- accounting type must agree in both directions. An explicitly declared Actual
-- default Commodity must agree with retained evidence; an omitted per-Account
-- default does not contradict the retained compatibility source.
--
-- This module also owns the read-only migration shadow from admitted retained
-- profiles to the strict declaration-only Account Journal syntax. That
-- projection carries only Account identity, AccountType, and optional default
-- Commodity. It does not move policy metadata or writer authority.
module HKernel.Household.AccountProfile.TSV
  ( AccountProfileTSVError(..)
  , parseRetainedAccountProfiles
  , validateRetainedAccountProfileRegistry
  , admitRetainedAccountProfiles
  , AccountJournalShadowError(..)
  , projectRetainedAccountDeclarations
  , renderAccountDeclarationsShadow
  , renderRetainedAccountJournalShadow
  , validateRetainedAccountJournalShadow
  ) where

import Data.Either (partitionEithers)
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import HKernel.Account
import HKernel.Account.Journal (parseAccountJournal)
import HKernel.Household.AccountProfile
import HKernel.Money (commodityCode, mkCommodity)

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

-- | Privacy-preserving failure from rendering and re-admitting one shadow.
--
-- The constructors identify only the failure coordinate or a count. They do not
-- retain Account names, source rows, or rendered Journal text, so a private
-- validation gate can report the failure kind without publishing source data.
data AccountJournalShadowError
  = AccountJournalShadowUnrepresentableDeclaration Int
  | AccountJournalShadowParseRejected Int
  | AccountJournalShadowAccountSetMismatch
  | AccountJournalShadowAccountTypeMismatch
  | AccountJournalShadowDefaultCommodityMismatch
  deriving (Eq, Show)

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
-- insufficient: accounting type and explicitly declared default Commodity are
-- independent coordinates. Actual omission means “not asserted here”, not a
-- contradictory Commodity declaration.
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

    commodityErrors sourceDeclaration actualDeclaration =
      case declaredAccountDefaultCommodity actualDeclaration of
        Nothing -> []
        Just actualCommodity
          | declaredAccountDefaultCommodity sourceDeclaration
              == Just actualCommodity -> []
          | otherwise ->
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
-- Account identity currently permits the Journal comment delimiter. Because
-- the existing parser would truncate such an identity, the renderer rejects it
-- rather than inventing an escape syntax or silently changing the declaration.
-- Exhaustive AccountType matching makes a future unhandled category a
-- compile-time failure.
renderAccountDeclarationsShadow
  :: [AccountDeclaration]
  -> Either (NonEmpty AccountJournalShadowError) Text
renderAccountDeclarationsShadow declarations =
  case length (filter (not . declarationIsRepresentable) ordered) of
    0 -> Right (T.intercalate "\n" (map renderDeclaration ordered))
    count -> Left
      (AccountJournalShadowUnrepresentableDeclaration count NonEmpty.:| [])
  where
    ordered = sortDeclarations declarations

-- | Render admitted retained profiles as a deterministic declaration Journal.
renderRetainedAccountJournalShadow
  :: Map Account RetainedAccountProfile
  -> Either (NonEmpty AccountJournalShadowError) Text
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
validateRetainedAccountJournalShadow profiles = do
  rendered <- renderAccountDeclarationsShadow expected
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

sortDeclarations :: [AccountDeclaration] -> [AccountDeclaration]
sortDeclarations = sortOn (accountName . declaredAccount)

declarationIsRepresentable :: AccountDeclaration -> Bool
declarationIsRepresentable =
  not . T.any (== ';') . accountName . declaredAccount

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
