{-# LANGUAGE OverloadedStrings #-}

-- | A small, strict parser for the journal syntax used by h-kernel.
--
-- Parsing is pure and reports source line numbers. Malformed input is never
-- turned into an empty journal and malformed postings are never discarded.
module HKernel.Journal
  ( Include
  , IncludeError(..)
  , mkInclude
  , includePath
  , JournalDocument
  , journalDocumentIncludes
  , resolveJournalDocumentIncludes
  , parseJournalDocument
  , validateJournalDocument
  , Journal
  , journalFromTransactions
  , journalAccountRegistry
  , journalTransactions
  , JournalError(..)
  , JournalErrorReason(..)
  , parseJournal
  ) where

import Data.Char (isSpace)
import Data.Either (partitionEithers)
import qualified Data.Foldable as Foldable
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty((:|)))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import HKernel.Account
  ( Account
  , AccountDeclaration
  , AccountError
  , AccountRegistry
  , AccountRegistryError(..)
  , AccountType(..)
  , accountName
  , declareAccount
  , declareAccountWithDefaultCommodity
  , declaredAccountDefaultCommodity
  , emptyAccountRegistry
  , lookupAccountDeclaration
  , mkAccount
  , registerAccount
  )
import HKernel.Ledger
  ( Posting
  , Transaction
  , TransactionError
  , mkPosting
  , mkTransaction
  , postingAccount
  , postingAmount
  )
import HKernel.Money

-- | A path named by an @include@ directive.
--
-- The constructor is hidden so an empty path cannot enter the IO loader. Path
-- resolution remains outside the pure journal parser.
newtype Include = Include { includePath :: Text }
  deriving (Eq, Show)

data IncludeError = EmptyIncludePath
  deriving (Eq, Show)

mkInclude :: Text -> Either IncludeError Include
mkInclude input
  | T.null path = Left EmptyIncludePath
  | otherwise   = Right (Include path)
  where
    path = T.strip input

-- | Pure syntax obtained from one source document.
--
-- This type may contain unresolved includes, so its constructor is hidden and
-- it cannot be mistaken for a validated 'Journal'.
newtype JournalDocument = JournalDocument [ParsedBlock]

data Journal = Journal
  { journalAccountRegistry :: AccountRegistry
  , journalTransactions    :: [Transaction]
  } deriving (Eq, Show)

journalFromTransactions :: Foldable collection => collection Transaction -> Journal
journalFromTransactions = Journal emptyAccountRegistry . Foldable.toList

data JournalError = JournalError
  { journalErrorLine   :: Int
  , journalErrorReason :: JournalErrorReason
  } deriving (Eq, Show)

data JournalErrorReason
  = InvalidTransactionHeader Text
  | UnexpectedIndentedLine Text
  | TransactionHasNoPostings
  | InvalidPostingAccount AccountError
  | UndeclaredPostingAccount Account
  | PostingCommodityMismatch Account Commodity Commodity
  | InvalidPostingQuantity QuantityError
  | InvalidPostingCommodity CommodityError
  | PostingAmountMissingCommodity Text
  | UnsupportedPostingSyntax Text
  | MultipleElidedAmounts [Int]
  | CannotInferElidedAmount Balance
  | InvalidTransaction TransactionError
  | InvalidAccountDirective Text
  | InvalidDeclaredAccount AccountError
  | InvalidAccountMetadata Text
  | InvalidAccountType Text
  | InvalidAccountCommodity CommodityError
  | AccountDirectiveHasNoType Account
  | DuplicateAccountType Account
  | DuplicateAccountCommodity Account
  | DuplicateAccountDirective Account
  | InvalidIncludeDirective Text
  | InvalidIncludePath IncludeError
  | UnresolvedInclude Include
  deriving (Eq, Show)

type LocatedLine = (Int, Text)
type LocatedPosting = (Int, Posting)

data Block = Block LocatedLine [LocatedLine]

data ParsedBlock
  = ParsedInclude Int Include
  | ParsedAccount Int AccountDeclaration
  | ParsedTransaction Transaction [LocatedPosting]
  | ParsedIgnored

data ParsedAccountMetadata
  = ParsedAccountType Int AccountType
  | ParsedAccountDefaultCommodity Int Commodity

data PartialPosting = PartialPosting
  { partialLine    :: Int
  , partialAccount :: Account
  , partialAmount  :: Maybe Amount
  }

journalDocumentIncludes :: JournalDocument -> [Include]
journalDocumentIncludes (JournalDocument blocks) =
  [ include
  | ParsedInclude _ include <- blocks
  ]

resolveJournalDocumentIncludes
  :: Applicative f
  => (Include -> f JournalDocument)
  -> JournalDocument
  -> f JournalDocument
resolveJournalDocumentIncludes resolve (JournalDocument blocks) =
  JournalDocument . concat <$> traverse resolveBlock blocks
  where
    resolveBlock (ParsedInclude _ include) =
      documentBlocks <$> resolve include
    resolveBlock block = pure [block]

    documentBlocks (JournalDocument includedBlocks) = includedBlocks

parseJournalDocument
  :: Text
  -> Either (NonEmpty JournalError) JournalDocument
parseJournalDocument input =
  errorsOrValue parseErrors (JournalDocument parsedBlocks)
  where
    locatedLines = zip [1..] (T.lines input)
    (structuralErrors, blocks) = collectBlocks locatedLines
    (nestedErrors, parsedBlocks) = partitionEithers (map parseBlock blocks)
    blockErrors = concatMap NonEmpty.toList nestedErrors
    parseErrors = structuralErrors ++ blockErrors

validateJournalDocument
  :: JournalDocument
  -> Either (NonEmpty JournalError) Journal
validateJournalDocument (JournalDocument parsedBlocks) =
  errorsOrValue validationErrors (Journal registry transactions)
  where
    includeErrors =
      [ JournalError lineNumber (UnresolvedInclude include)
      | ParsedInclude lineNumber include <- parsedBlocks
      ]
    (registryErrors, registry) = buildRegistry parsedBlocks
    postingErrors = validatePostings registry parsedBlocks
    transactions =
      [ transaction
      | ParsedTransaction transaction _ <- parsedBlocks
      ]
    validationErrors
      | null includeErrors = registryErrors ++ postingErrors
      | otherwise = includeErrors

parseJournal :: Text -> Either (NonEmpty JournalError) Journal
parseJournal input =
  parseJournalDocument input >>= validateJournalDocument

collectBlocks :: [LocatedLine] -> ([JournalError], [Block])
collectBlocks = finish . go Nothing [] []
  where
    go current errors blocks [] = (current, errors, blocks)
    go current errors blocks (located@(_, line):rest)
      | T.null (T.strip line) =
          go Nothing errors (store current blocks) rest
      | isIndented line && isComment line = case current of
          Just (Block header bodyLines)
            | isDirective "account" (snd header) ->
                go (Just (Block header (located : bodyLines))) errors blocks rest
          _ -> go current errors blocks rest
      | isComment line =
          go current errors blocks rest
      | isIndented line = case current of
          Just (Block header bodyLines) ->
            go (Just (Block header (located : bodyLines))) errors blocks rest
          Nothing ->
            let err = at located (UnexpectedIndentedLine line)
            in go Nothing (err : errors) blocks rest
      | otherwise =
          go (Just (Block located [])) errors (store current blocks) rest

    finish (current, errors, blocks) =
      (reverse errors, reverse (store current blocks))

    store Nothing stored = stored
    store (Just (Block header bodyLines)) stored =
      Block header (reverse bodyLines) : stored

parseBlock :: Block -> Either (NonEmpty JournalError) ParsedBlock
parseBlock block@(Block (_, headerText) _)
  | isDirective "include" headerText = parseIncludeBlock block
  | isDirective "account" headerText = parseAccountBlock block
  | isDirective "commodity" headerText = Right ParsedIgnored
  | otherwise = do
      (transaction, locatedPostings) <- parseTransactionBlock block
      Right (ParsedTransaction transaction locatedPostings)

parseIncludeBlock :: Block -> Either (NonEmpty JournalError) ParsedBlock
parseIncludeBlock (Block header bodyLines) = case bodyLines of
  [] -> do
    include <- firstError (parseIncludeHeader header)
    Right (ParsedInclude (fst header) include)
  located:rest -> Left
    ( at located (UnexpectedIndentedLine (snd located))
    :| [ at extra (UnexpectedIndentedLine (snd extra))
       | extra <- rest
       ]
    )

parseIncludeHeader :: LocatedLine -> Either JournalError Include
parseIncludeHeader located@(_, originalLine) =
  case T.stripPrefix "include" body of
    Nothing -> Left (at located (InvalidIncludeDirective originalLine))
    Just remainder -> case mkInclude remainder of
      Left err      -> Left (at located (InvalidIncludePath err))
      Right include -> Right include
  where
    body = T.stripEnd (T.takeWhile (/= ';') (T.stripStart originalLine))

parseAccountBlock :: Block -> Either (NonEmpty JournalError) ParsedBlock
parseAccountBlock (Block header metadataLines) = do
  account <- firstError (parseAccountHeader header)
  let (metadataErrors, maybeMetadata) =
        partitionEithers (map parseAccountMetadata metadataLines)
      metadata = [m | Just m <- maybeMetadata]
  case metadataErrors of
    err:errs -> Left (err :| errs)
    [] -> assembleAccountDeclaration header account metadata

assembleAccountDeclaration
  :: LocatedLine
  -> Account
  -> [ParsedAccountMetadata]
  -> Either (NonEmpty JournalError) ParsedBlock
assembleAccountDeclaration header account metadata =
  case declarationErrors of
    err:errs -> Left (err :| errs)
    [] -> case effectiveType of
      Just accountType -> Right
        (ParsedAccount (fst header) (makeDeclaration accountType))
      Nothing -> Left (at header (AccountDirectiveHasNoType account) :| [])
  where
    typeEntries =
      [ (lineNumber, accountType)
      | ParsedAccountType lineNumber accountType <- metadata
      ]
    commodityEntries =
      [ (lineNumber, commodity)
      | ParsedAccountDefaultCommodity lineNumber commodity <- metadata
      ]

    effectiveType = case typeEntries of
      (_, t):_ -> Just t
      []       -> Nothing

    declarationErrors =
      missingTypeError
        ++ [ JournalError lineNumber (DuplicateAccountType account)
           | (lineNumber, _) <- drop 1 typeEntries
           ]
        ++ [ JournalError lineNumber (DuplicateAccountCommodity account)
           | (lineNumber, _) <- drop 1 commodityEntries
           ]

    missingTypeError = case effectiveType of
      Nothing -> [at header (AccountDirectiveHasNoType account)]
      Just _  -> []

    makeDeclaration accountType = case commodityEntries of
      [] -> declareAccount account accountType
      (_, commodity):_ ->
        declareAccountWithDefaultCommodity account accountType commodity

parseAccountHeader :: LocatedLine -> Either JournalError Account
parseAccountHeader located@(_, originalLine) =
  case T.stripPrefix "account" body of
    Nothing -> Left (at located (InvalidAccountDirective originalLine))
    Just remainder ->
      let accountText = T.strip remainder
      in if T.null accountText
          then Left (at located (InvalidAccountDirective originalLine))
          else case mkAccount accountText of
            Left err -> Left (at located (InvalidDeclaredAccount err))
            Right account -> Right account
  where
    body = T.stripEnd (T.takeWhile (/= ';') (T.stripStart originalLine))

parseAccountMetadata
  :: LocatedLine
  -> Either JournalError (Maybe ParsedAccountMetadata)
parseAccountMetadata located@(lineNumber, originalLine) =
  let cleanLine = T.strip (T.dropWhile (\c -> c == ';' || isSpace c) (T.strip originalLine))
  in case T.breakOn ":" cleanLine of
    (_, remainder) | T.null remainder ->
      Right Nothing
    (key, remainder)
      | normalizedKey `elem` ["type", "role"] ->
          Just . ParsedAccountType lineNumber
            <$> parseAccountType located value
      | normalizedKey == "commodity" ->
          Just . ParsedAccountDefaultCommodity lineNumber
            <$> parseAccountCommodity located value
      | otherwise ->
          Right Nothing
      where
        normalizedKey = T.toCaseFold (T.strip key)
        value = T.strip (T.drop 1 remainder)

parseAccountType :: LocatedLine -> Text -> Either JournalError AccountType
parseAccountType located value =
  case T.toCaseFold value of
    "asset"     -> Right Asset
    "liability" -> Right Liability
    "equity"    -> Right Equity
    "income"    -> Right Income
    "expense"   -> Right Expense
    "budget"    -> Right Budget
    _           -> Left (at located (InvalidAccountType value))

parseAccountCommodity :: LocatedLine -> Text -> Either JournalError Commodity
parseAccountCommodity located value =
  case mkCommodity value of
    Left err -> Left (at located (InvalidAccountCommodity err))
    Right commodity -> Right commodity

buildRegistry :: [ParsedBlock] -> ([JournalError], AccountRegistry)
buildRegistry = finish . Foldable.foldl' add ([], emptyAccountRegistry)
  where
    add state (ParsedInclude _ _) = state
    add state (ParsedTransaction _ _) = state
    add state ParsedIgnored = state
    add (errors, registry) (ParsedAccount lineNumber declaration) =
      case registerAccount declaration registry of
        Right updated -> (errors, updated)
        Left (DuplicateAccountDeclaration account) ->
          ( JournalError lineNumber (DuplicateAccountDirective account) : errors
          , registry
          )

    finish (errors, registry) = (reverse errors, registry)

validatePostings :: AccountRegistry -> [ParsedBlock] -> [JournalError]
validatePostings registry = concatMap validateBlock
  where
    validateBlock (ParsedInclude _ _) = []
    validateBlock (ParsedAccount _ _) = []
    validateBlock ParsedIgnored = []
    validateBlock (ParsedTransaction _ locatedPostings) =
      concatMap validatePosting locatedPostings

    validatePosting (lineNumber, posting) =
      case lookupAccountDeclaration account registry of
        Nothing ->
          [JournalError lineNumber (UndeclaredPostingAccount account)]
        Just declaration ->
          case declaredAccountDefaultCommodity declaration of
            Just expected
              | expected /= actual ->
                  [ JournalError lineNumber
                      (PostingCommodityMismatch account expected actual)
                  ]
            _ -> []
      where
        account = postingAccount posting
        actual = amountCommodity (postingAmount posting)

parseTransactionBlock
  :: Block
  -> Either (NonEmpty JournalError) (Transaction, [LocatedPosting])
parseTransactionBlock (Block header postingLines) = do
  (date, description) <- firstError (parseHeader header)
  if null postingLines
    then Left (at header TransactionHasNoPostings :| [])
    else do
      let (postingErrors, partials) = partitionEithers (map parsePosting postingLines)
      case postingErrors of
        err:errs -> Left (err :| errs)
        [] -> do
          postings <- completePostings header partials
          case mkTransaction date description postings of
            Left err -> Left (at header (InvalidTransaction err) :| [])
            Right transaction -> Right
              ( transaction
              , zip (map partialLine partials) (NonEmpty.toList postings)
              )

parseHeader :: LocatedLine -> Either JournalError (Day, Text)
parseHeader located@(_, line) =
  case parseDate dateText of
    Nothing -> Left (at located (InvalidTransactionHeader line))
    Just date
      | T.null description -> Left (at located (InvalidTransactionHeader line))
      | otherwise          -> Right (date, description)
  where
    dateText = T.take 10 line
    remainder = T.stripStart (T.drop 10 line)
    description = case T.uncons remainder of
      Just (status, rest) | status == '*' || status == '!' -> T.stripStart rest
      _ -> remainder

    parseDate text
      | T.length text /= 10 = Nothing
      | otherwise = parseTimeM True defaultTimeLocale "%Y-%m-%d" (T.unpack text)

parsePosting :: LocatedLine -> Either JournalError PartialPosting
parsePosting located@(lineNumber, originalLine) = do
  let body = T.stripEnd (T.takeWhile (/= ';') (T.dropWhile isSpace originalLine))
      (accountText, amountText) = splitPosting body
  account <- case mkAccount accountText of
    Left err -> Left (at located (InvalidPostingAccount err))
    Right value -> Right value
  amount <- traverse (parseAmount located) amountText
  Right (PartialPosting lineNumber account amount)

parseAmount :: LocatedLine -> Text -> Either JournalError Amount
parseAmount located amountText = case T.words amountText of
  [quantityText] ->
    Left (at located (PostingAmountMissingCommodity quantityText))
  [quantityText, commodityText] -> do
    quantity <- case parseQuantity quantityText of
      Left err -> Left (at located (InvalidPostingQuantity err))
      Right value -> Right value
    commodity <- case mkCommodity commodityText of
      Left err -> Left (at located (InvalidPostingCommodity err))
      Right value -> Right value
    Right (mkAmount commodity quantity)
  _ -> Left (at located (UnsupportedPostingSyntax amountText))

completePostings
  :: LocatedLine
  -> [PartialPosting]
  -> Either (NonEmpty JournalError) (NonEmpty Posting)
completePostings header partials =
  case missing of
    [] -> finishPostings (traverse explicitPosting partials)
    [omitted] -> do
      inferred <- inferAmount omitted explicitBalance
      finishPostings (traverse (complete omitted inferred) partials)
    _ -> Left (at header (MultipleElidedAmounts (map partialLine missing)) :| [])
  where
    missing = filter (maybe True (const False) . partialAmount) partials
    explicitAmounts = [amount | PartialPosting _ _ (Just amount) <- partials]
    explicitBalance = balanceFromAmounts explicitAmounts

    explicitPosting (PartialPosting _ account amount) =
      mkPosting account <$> amount

    complete omitted inferred partial
      | partialLine partial == partialLine omitted =
          Just (mkPosting (partialAccount partial) inferred)
      | otherwise = explicitPosting partial

    inferAmount omitted balance = case balanceEntries balance of
      [(commodity, quantity)] ->
        Right (mkAmount commodity (negateQuantity quantity))
      _ -> Left (JournalError (partialLine omitted) (CannotInferElidedAmount balance) :| [])

    finishPostings maybePostings = case maybePostings >>= NonEmpty.nonEmpty of
      Just values -> Right values
      Nothing -> Left (at header TransactionHasNoPostings :| [])

splitPosting :: Text -> (Text, Maybe Text)
splitPosting body = case separatorIndex body of
  Nothing -> (body, Nothing)
  Just index ->
    let account = T.take index body
        remainder = T.dropWhile isSpace (T.drop index body)
    in (account, if T.null remainder then Nothing else Just remainder)

-- A tab or two consecutive spaces separate an account name from its amount.
-- A single ordinary space remains legal inside an account name.
separatorIndex :: Text -> Maybe Int
separatorIndex = go 0 . T.unpack
  where
    go _ [] = Nothing
    go index ('\t':_) = Just index
    go index (' ':' ':_) = Just index
    go index (_:rest) = go (index + 1) rest

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
  Nothing             -> False

errorsOrValue
  :: [JournalError]
  -> value
  -> Either (NonEmpty JournalError) value
errorsOrValue errors value = case sortOn journalErrorLine errors of
  []       -> Right value
  err:errs -> Left (err :| errs)

firstError
  :: Either JournalError value
  -> Either (NonEmpty JournalError) value
firstError = either (Left . (:| [])) Right

at :: LocatedLine -> JournalErrorReason -> JournalError
at (lineNumber, _) = JournalError lineNumber
