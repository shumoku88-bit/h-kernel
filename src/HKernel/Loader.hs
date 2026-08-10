-- | IO boundary for loading a journal document graph.
--
-- Path resolution and file reads live here. Parsing, include substitution, and
-- journal validation remain pure operations owned by 'HKernel.Journal'.
module HKernel.Loader
  ( IncludeTrace(..)
  , JournalReadFailure(..)
  , LoadError(..)
  , JournalRootObservation
  , journalRootObservationJournal
  , journalRootObservationTransactionSources
  , loadJournal
  , loadJournalFromRootSource
  , loadJournalRootObservationFromSource
  ) where

import Control.Exception (IOException, try)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE)
import Control.Monad.Trans.State.Strict (StateT, evalStateT, get, put)
import Data.Bifunctor (first)
import Data.List.NonEmpty (NonEmpty((:|)))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import qualified Data.Text.IO as TIO
import HKernel.Journal
  ( Include
  , Journal
  , JournalDocument
  , JournalError
  , JournalTransactionSource
  , includePath
  , journalDocumentTransactionSources
  , parseJournalDocument
  , resolveJournalDocumentIncludes
  , validateJournalDocument
  )
import System.FilePath ((</>), isAbsolute, normalise, takeDirectory)

-- | One root-to-file traversal through the include graph.
--
-- The path is non-empty and ordered from the root journal to the reached file.
newtype IncludeTrace = IncludeTrace
  { includeTracePath :: NonEmpty FilePath
  } deriving (Eq, Show)

-- | One failed file read together with the complete include traversal that led
-- to it. The path is always non-empty and ordered from the root journal to the
-- file whose read raised the 'IOException'.
data JournalReadFailure = JournalReadFailure
  { journalReadPath      :: NonEmpty FilePath
  , journalReadException :: IOException
  } deriving (Show)

data LoadError
  = JournalReadFailed JournalReadFailure
  | JournalParseFailed FilePath (NonEmpty JournalError)
  | JournalValidationFailed (NonEmpty JournalError)
  | IncludeAlreadyLoaded
      { firstIncludeTrace    :: IncludeTrace
      , repeatedIncludeTrace :: IncludeTrace
      }
  | IncludeCycle (NonEmpty FilePath)
  deriving (Show)

-- | One short-lived root-source observation.
--
-- The resolved Journal and the root transaction-source evidence are produced
-- from one parse of the supplied root bytes. Included documents still resolve
-- from the filesystem, but their physical coordinates never enter the root
-- evidence. The constructor stays private so callers cannot fabricate this
-- pairing directly.
data JournalRootObservation = JournalRootObservation
  { journalRootObservationJournal            :: Journal
  , journalRootObservationTransactionSources :: [JournalTransactionSource]
  }

newtype LoadedFiles = LoadedFiles (Map FilePath IncludeTrace)

type Loader = StateT LoadedFiles (ExceptT LoadError IO)

emptyLoadedFiles :: LoadedFiles
emptyLoadedFiles = LoadedFiles Map.empty

-- | Load, recursively expand, and validate a journal rooted at one file.
--
-- Relative includes are resolved from the directory of the document that names
-- them. Every recursive step carries one non-empty root-to-file trace. That
-- trace owns cycle detection, duplicate diagnostics, and read-failure context,
-- so path ancestry cannot drift away from the file currently being loaded.
loadJournal :: FilePath -> IO (Either LoadError Journal)
loadJournal rootPath =
  runLoader (loadDocument (rootTrace rootPath))

-- | Load a journal graph while treating an already observed root source as the
-- exact root bytes for this admission. Included files are still resolved from
-- disk relative to the supplied root path.
--
-- This compatibility projection keeps callers that need only the resolved
-- Journal while the richer root observation remains available to domain
-- admissions that also consume parser-owned root source evidence.
loadJournalFromRootSource
  :: FilePath
  -> Text
  -> IO (Either LoadError Journal)
loadJournalFromRootSource rootPath rootSource =
  fmap (fmap journalRootObservationJournal)
    (loadJournalRootObservationFromSource rootPath rootSource)

-- | Load exact root bytes once, retain their root-only transaction evidence,
-- resolve includes, and validate the complete Journal graph.
--
-- This is intentionally not a source cache or full provenance map. It preserves
-- only the parser evidence needed by current root-owned domain admission while
-- keeping include resolution and validation unchanged.
loadJournalRootObservationFromSource
  :: FilePath
  -> Text
  -> IO (Either LoadError JournalRootObservation)
loadJournalRootObservationFromSource rootPath rootSource = runExceptT
  (evalStateT load emptyLoadedFiles)
  where
    load = do
      (rootDocument, resolvedDocument) <-
        loadRootDocuments (rootTrace rootPath) rootSource
      journal <- fromEither
        (first JournalValidationFailed (validateJournalDocument resolvedDocument))
      pure JournalRootObservation
        { journalRootObservationJournal = journal
        , journalRootObservationTransactionSources =
            journalDocumentTransactionSources rootDocument
        }

runLoader :: Loader JournalDocument -> IO (Either LoadError Journal)
runLoader loadRoot = runExceptT
  (evalStateT load emptyLoadedFiles)
  where
    load = do
      document <- loadRoot
      fromEither
        (first JournalValidationFailed (validateJournalDocument document))

loadRootDocument :: IncludeTrace -> Text -> Loader JournalDocument
loadRootDocument trace source =
  snd <$> loadRootDocuments trace source

loadRootDocuments
  :: IncludeTrace
  -> Text
  -> Loader (JournalDocument, JournalDocument)
loadRootDocuments trace source = do
  loadedFiles <- get
  admittedFiles <- fromEither (admitFile trace loadedFiles)
  put admittedFiles
  document <- fromEither
    (first (JournalParseFailed path) (parseJournalDocument source))
  resolved <- resolveJournalDocumentIncludes
    (loadDocument . extendTrace trace . resolveInclude path)
    document
  pure (document, resolved)
  where
    path = traceDestination trace

loadDocument :: IncludeTrace -> Loader JournalDocument
loadDocument trace = do
  loadedFiles <- get
  admittedFiles <- fromEither (admitFile trace loadedFiles)
  put admittedFiles
  document <- readDocument trace
  resolveJournalDocumentIncludes
    (loadDocument . extendTrace trace . resolveInclude path)
    document
  where
    path = traceDestination trace

admitFile
  :: IncludeTrace
  -> LoadedFiles
  -> Either LoadError LoadedFiles
admitFile trace loadedFiles
  | path `elem` traceAncestors trace = Left (IncludeCycle (cyclePath trace))
  | Just firstTrace <- lookupLoaded path loadedFiles =
      Left (IncludeAlreadyLoaded firstTrace trace)
  | otherwise = Right (insertLoaded path trace loadedFiles)
  where
    path = traceDestination trace

lookupLoaded :: FilePath -> LoadedFiles -> Maybe IncludeTrace
lookupLoaded path (LoadedFiles paths) = Map.lookup path paths

insertLoaded :: FilePath -> IncludeTrace -> LoadedFiles -> LoadedFiles
insertLoaded path trace (LoadedFiles paths) =
  LoadedFiles (Map.insert path trace paths)

readDocument :: IncludeTrace -> Loader JournalDocument
readDocument trace = do
  content <- fromEither . first readFailure =<< liftIO (readText path)
  fromEither
    (first (JournalParseFailed path) (parseJournalDocument content))
  where
    path = traceDestination trace
    readFailure = JournalReadFailed
      . JournalReadFailure (includeTracePath trace)

readText :: FilePath -> IO (Either IOException Text)
readText = try . TIO.readFile

resolveInclude :: FilePath -> Include -> FilePath
resolveInclude parent include = normalise resolved
  where
    child = T.unpack (includePath include)
    resolved
      | isAbsolute child = child
      | otherwise = takeDirectory parent </> child

rootTrace :: FilePath -> IncludeTrace
rootTrace path = IncludeTrace (normalise path :| [])

extendTrace :: IncludeTrace -> FilePath -> IncludeTrace
extendTrace trace path =
  IncludeTrace (includeTracePath trace <> (path :| []))

traceDestination :: IncludeTrace -> FilePath
traceDestination = NonEmpty.last . includeTracePath

traceAncestors :: IncludeTrace -> [FilePath]
traceAncestors = NonEmpty.init . includeTracePath

cyclePath :: IncludeTrace -> NonEmpty FilePath
cyclePath trace =
  repeated :| (reverse (takeWhile (/= repeated) ancestors) ++ [repeated])
  where
    repeated = traceDestination trace
    ancestors = reverse (traceAncestors trace)

fromEither :: Either LoadError value -> Loader value
fromEither = either (lift . throwE) pure
