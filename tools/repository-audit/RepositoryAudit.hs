{-# LANGUAGE OverloadedStrings #-}

-- | Pure repository inventory and audit rules.
--
-- Git, Cabal, and the filesystem remain outside this module. They supply typed
-- paths and one explicit document index; this module only compares ownership.
module RepositoryAudit
  ( RepositoryPath
  , RepositoryPathError(..)
  , mkRepositoryPath
  , repositoryPathText
  , parseNulSeparatedPaths
  , DocumentRole(..)
  , DocumentEntry
  , documentEntry
  , documentEntryPath
  , documentEntryRole
  , DocumentIndex
  , DocumentIndexError(..)
  , mkDocumentIndex
  , parseDocumentIndex
  , lookupDocumentRole
  , RepositoryInventory
  , repositoryInventory
  , Finding(..)
  , auditRepository
  , renderFinding
  ) where

import Data.Char (isControl)
import Data.Either (partitionEithers)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified System.FilePath.Posix as Posix
import Toml (decode)
import Toml.Schema
  ( FromValue(..)
  , Result(..)
  , parseTableFromValue
  , reqKey
  )

-- | Canonical repository-relative path. Repository paths use forward slashes on
-- every host so Git and Cabal inventories can be compared without OS-specific
-- separators leaking into the pure audit.
newtype RepositoryPath = RepositoryPath
  { repositoryPathText :: Text
  } deriving (Eq, Ord, Show)

data RepositoryPathError
  = EmptyRepositoryPath
  | AbsoluteRepositoryPath Text
  | RepositoryPathContainsParentTraversal Text
  | RepositoryPathContainsControlCharacter Text
  deriving (Eq, Show)

mkRepositoryPath :: Text -> Either RepositoryPathError RepositoryPath
mkRepositoryPath raw
  | T.null raw = Left EmptyRepositoryPath
  | T.any isControl raw = Left (RepositoryPathContainsControlCharacter raw)
  | Posix.isAbsolute slashPath = Left (AbsoluteRepositoryPath raw)
  | ".." `elem` Posix.splitDirectories slashPath =
      Left (RepositoryPathContainsParentTraversal raw)
  | canonical == "." = Left EmptyRepositoryPath
  | otherwise = Right (RepositoryPath (T.pack canonical))
  where
    slashPath = map normalizeSeparator (T.unpack raw)
    canonical = Posix.normalise slashPath

    normalizeSeparator '\\' = '/'
    normalizeSeparator char = char

-- | Parse NUL-separated path output such as @git ls-files -z@ or
-- @cabal sdist --list-only --null-sep@.
parseNulSeparatedPaths
  :: Text
  -> Either [RepositoryPathError] [RepositoryPath]
parseNulSeparatedPaths input =
  case partitionEithers (map mkRepositoryPath rawPaths) of
    ([], paths) -> Right paths
    (errors, _) -> Left errors
  where
    rawPaths = filter (not . T.null) (T.splitOn "\0" input)

-- | Why one Markdown document belongs in the repository.
data DocumentRole
  = Policy
  | Architecture
  | Contract
  | Observation
  | Reference
  deriving (Eq, Ord, Show)

data DocumentEntry = DocumentEntry
  { documentEntryPath :: RepositoryPath
  , documentEntryRole :: DocumentRole
  } deriving (Eq, Show)

documentEntry :: RepositoryPath -> DocumentRole -> DocumentEntry
documentEntry = DocumentEntry

newtype DocumentIndex = DocumentIndex
  { indexedDocuments :: Map RepositoryPath DocumentRole
  } deriving (Eq, Show)

data DocumentIndexError
  = IndexedPathIsNotMarkdownDocument RepositoryPath
  | DuplicateIndexedDocument RepositoryPath
  deriving (Eq, Show)

mkDocumentIndex
  :: [DocumentEntry]
  -> Either (NonEmpty DocumentIndexError) DocumentIndex
mkDocumentIndex entries =
  case NonEmpty.nonEmpty errors of
    Just nonEmptyErrors -> Left nonEmptyErrors
    Nothing -> Right (DocumentIndex (Map.fromList coordinates))
  where
    coordinates =
      [ (documentEntryPath entry, documentEntryRole entry)
      | entry <- entries
      ]
    occurrenceCounts = Map.fromListWith (+)
      [ (path, 1 :: Int)
      | (path, _) <- coordinates
      ]
    invalidPathErrors =
      [ IndexedPathIsNotMarkdownDocument path
      | (path, _) <- coordinates
      , not (isMarkdownDocument path)
      ]
    duplicateErrors =
      [ DuplicateIndexedDocument path
      | (path, count) <- Map.toAscList occurrenceCounts
      , count > 1
      ]
    errors = invalidPathErrors ++ duplicateErrors

lookupDocumentRole :: RepositoryPath -> DocumentIndex -> Maybe DocumentRole
lookupDocumentRole path = Map.lookup path . indexedDocuments

data RawDocumentIndex = RawDocumentIndex [RawDocument]

data RawDocument = RawDocument Text Text

instance FromValue RawDocumentIndex where
  fromValue = parseTableFromValue
    (RawDocumentIndex <$> reqKey "documents")

instance FromValue RawDocument where
  fromValue = parseTableFromValue
    (RawDocument
      <$> reqKey "path"
      <*> reqKey "role")

-- | Decode the document index. Unknown TOML keys are rejected rather than
-- silently ignored.
parseDocumentIndex :: Text -> Either [Text] DocumentIndex
parseDocumentIndex input =
  case (decode input :: Result String RawDocumentIndex) of
    Failure errors -> Left (map T.pack errors)
    Success warnings raw
      | null warnings -> rawToDocumentIndex raw
      | otherwise -> Left (map T.pack warnings)

rawToDocumentIndex :: RawDocumentIndex -> Either [Text] DocumentIndex
rawToDocumentIndex (RawDocumentIndex rawDocuments) =
  case syntaxErrors of
    [] -> case mkDocumentIndex entries of
      Right documentIndex -> Right documentIndex
      Left errors -> Left
        (map renderDocumentIndexError (NonEmpty.toList errors))
    _ -> Left syntaxErrors
  where
    (errorGroups, entries) = partitionEithers
      (zipWith parseRawDocument [0 :: Int ..] rawDocuments)
    syntaxErrors = concat errorGroups

parseRawDocument :: Int -> RawDocument -> Either [Text] DocumentEntry
parseRawDocument index (RawDocument rawPath rawRole) =
  case (pathResult, roleResult, errors) of
    (Right repositoryPath, Right role, []) ->
      Right (DocumentEntry repositoryPath role)
    _ -> Left errors
  where
    pathResult = mkRepositoryPath rawPath
    roleResult = parseDocumentRole rawRole
    diagnosticPath = indexedPath index
    errors =
      either
        (pure . renderRepositoryPathError (diagnosticPath <> ".path"))
        (const [])
        pathResult
        ++ either
          (pure . renderDocumentRoleError (diagnosticPath <> ".role"))
          (const [])
          roleResult

parseDocumentRole :: Text -> Either Text DocumentRole
parseDocumentRole "policy" = Right Policy
parseDocumentRole "architecture" = Right Architecture
parseDocumentRole "contract" = Right Contract
parseDocumentRole "observation" = Right Observation
parseDocumentRole "reference" = Right Reference
parseDocumentRole value = Left value

indexedPath :: Int -> Text
indexedPath index = "documents[" <> T.pack (show index) <> "]"

renderRepositoryPathError :: Text -> RepositoryPathError -> Text
renderRepositoryPathError path err = path <> ": " <> case err of
  EmptyRepositoryPath -> "expected a non-empty repository-relative path"
  AbsoluteRepositoryPath value ->
    "absolute paths are not allowed; got " <> quoted value
  RepositoryPathContainsParentTraversal value ->
    "parent traversal is not allowed; got " <> quoted value
  RepositoryPathContainsControlCharacter value ->
    "control characters are not allowed; got " <> quoted value

renderDocumentRoleError :: Text -> Text -> Text
renderDocumentRoleError path value =
  path <> ": expected policy, architecture, contract, observation, or reference; got "
    <> quoted value

renderDocumentIndexError :: DocumentIndexError -> Text
renderDocumentIndexError err = case err of
  IndexedPathIsNotMarkdownDocument path ->
    "documents: expected a Markdown path below docs/; got "
      <> quoted (repositoryPathText path)
  DuplicateIndexedDocument path ->
    "documents: duplicate path " <> quoted (repositoryPathText path)

-- | Repository facts admitted from external owners.
data RepositoryInventory = RepositoryInventory
  { trackedFiles  :: Set RepositoryPath
  , packagedFiles :: Set RepositoryPath
  , documentIndex :: DocumentIndex
  } deriving (Eq, Show)

repositoryInventory
  :: [RepositoryPath]
  -> [RepositoryPath]
  -> DocumentIndex
  -> RepositoryInventory
repositoryInventory tracked packaged index = RepositoryInventory
  { trackedFiles = Set.fromList tracked
  , packagedFiles = Set.fromList packaged
  , documentIndex = index
  }

-- | Integrity findings in ownership order: Cabal source ownership, document
-- index coverage, then stale index entries.
data Finding
  = UnregisteredHaskellFile RepositoryPath
  | UnindexedDocument RepositoryPath
  | MissingIndexedDocument RepositoryPath
  deriving (Eq, Show)

auditRepository :: RepositoryInventory -> [Finding]
auditRepository inventory =
  map UnregisteredHaskellFile (Set.toAscList unregisteredHaskell)
    ++ map UnindexedDocument (Set.toAscList unindexedDocuments)
    ++ map MissingIndexedDocument (Set.toAscList missingDocuments)
  where
    tracked = trackedFiles inventory
    packaged = packagedFiles inventory
    indexed = Map.keysSet (indexedDocuments (documentIndex inventory))
    trackedHaskell = Set.filter isHaskellFile tracked
    trackedDocuments = Set.filter isMarkdownDocument tracked
    unregisteredHaskell = trackedHaskell `Set.difference` packaged
    unindexedDocuments = trackedDocuments `Set.difference` indexed
    missingDocuments = indexed `Set.difference` tracked

renderFinding :: Finding -> Text
renderFinding finding = case finding of
  UnregisteredHaskellFile path ->
    "Cabal does not own tracked Haskell source: " <> repositoryPathText path
  UnindexedDocument path ->
    "tracked Markdown document is absent from docs/INDEX.toml: "
      <> repositoryPathText path
  MissingIndexedDocument path ->
    "docs/INDEX.toml names a document that Git does not track: "
      <> repositoryPathText path

isHaskellFile :: RepositoryPath -> Bool
isHaskellFile = hasExtension [".hs", ".lhs"]

isMarkdownDocument :: RepositoryPath -> Bool
isMarkdownDocument path =
  "docs/" `T.isPrefixOf` value && ".md" `T.isSuffixOf` value
  where
    value = repositoryPathText path

hasExtension :: [Text] -> RepositoryPath -> Bool
hasExtension extensions path =
  any (`T.isSuffixOf` repositoryPathText path) extensions

quoted :: Text -> Text
quoted value = "‘" <> value <> "’"
