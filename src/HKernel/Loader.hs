-- | IO boundary for loading a journal document graph.
--
-- Path resolution and file reads live here. Parsing, include substitution, and
-- journal validation remain pure operations owned by 'HKernel.Journal'.
module HKernel.Loader
  ( IncludeTrace(..)
  , JournalReadFailure(..)
  , LoadError(..)
  , loadJournal
  , loadJournalFromRootSource
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
  , includePath
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
  runLoader rootPath (loadDocument (rootTrace rootPath))

-- | Load a journal graph while treating an already observed root source as the
-- exact root bytes for this admission. Included files are still resolved from
-- disk relative to the supplied root path.
--
-- This is the filesystem counterpart of a write snapshot: callers can bind a
-- preview or application state to the same root bytes later used as
-- expected-old without re-reading the root during graph admission.
loadJournalFromRootSource
  :: FilePath
  -> Text
  -> IO (Either LoadError Journal)
loadJournalFromRootSource rootPath rootSource =
  runLoader rootPath (loadRootDocument (rootTrace rootPath) rootSource)

runLoader :: FilePath -> Loader JournalDocument -> IO (Either LoadError Journal)
runLoader _ loadRoot = runExceptT
  (evalStateT load emptyLoadedFiles)
  where
    load = do
      document <- loadRoot
      fromEither
        (first JournalValidationFailed (validateJournalDocument document))

loadRootDocument :: IncludeTrace -> Text -> Loader JournalDocument
loadRootDocument trace source = do
  loadedFiles <- get
  admittedFiles <- fromEither (admitFile trace loadedFiles)
  put admittedFiles
  document <- fromEither
    (first (JournalParseFailed path) (parseJournalDocument source))
  resolveJournalDocumentIncludes
    (loadDocument . extendTrace trace . resolveInclude path)
    document
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
