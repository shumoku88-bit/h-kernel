{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad.IO.Class (liftIO)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.LocalTime (getZonedTime, localDay, zonedTimeToLocalTime)
import System.Console.Haskeline
  ( InputT
  , defaultSettings
  , getInputLine
  , outputStrLn
  , runInputT
  )
import System.Environment (getArgs)
import System.Exit (die)
import Text.Read (readMaybe)

import HKernel.Account
  ( Account
  , AccountRegistry
  , accountName
  , declaredAccountDefaultCommodity
  , lookupAccountDeclaration
  )
import HKernel.Actual.Journal
  ( actualJournalTransactionEntries
  , actualJournalValue
  , actualTransactionEntryTransaction
  )
import HKernel.Application.Config
  ( HouseholdRoot
  , HouseholdSourcePaths(..)
  , mkHouseholdRoot
  )
import HKernel.Editor.ActualAppend
  ( ActualAddInput(..)
  , ActualAddPreview(..)
  , prepareActualAddPreviewFromResolvedJournal
  )
import HKernel.Editor.EntitlementTransferAppend
  ( EntitlementTransferAppendPreview(..)
  , prepareCurrentEntitlementTransferAppend
  )
import HKernel.Editor.Interaction.ActualAdd
  ( AccountSelectionTarget(..)
  , dailyAccountCandidates
  , incomeAccountCandidates
  )
import HKernel.Editor.SourcePublication
  ( CandidateSource(..)
  , ExpectedSource(..)
  , WriteIntent(..)
  , publishActualBlockWithPathAdmission
  , publishWithPathAdmission
  )
import HKernel.Envelope.EntitlementTransfer
  ( EnvelopeEndpoint(..)
  , mkEnvelopeEntitlementTransfer
  )
import HKernel.Envelope.Identity
  ( EnvelopeId
  , envelopeIdText
  )
import HKernel.Household.Application
  ( HouseholdState(..)
  , HouseholdWriteSnapshot(..)
  , loadCanonicalHousehold
  , loadCanonicalHouseholdWriteSnapshot
  )
import HKernel.Household.EnvelopeHistory (householdEnvelopeRegistry)
import HKernel.Household.Policy
  ( householdEnvelopeOrder
  )
import HKernel.Money
  ( Amount
  , Commodity
  , commodityCode
  , mkAmount
  , mkCommodity
  , parseQuantity
  , quantityToRational
  )

-- This executable is intentionally a concrete delivery experiment rather than
-- a command framework. It asks one question at a time and delegates accounting
-- meaning, candidate preparation, admission, and publication to existing owners.

data MainChoice
  = RecordExpense
  | RecordIncome
  | ManageEnvelopeMoney
  | QuitDialogue

newtype EnvelopeChoice = EnvelopeChoice
  { choiceEnvelopeId :: EnvelopeId
  }

data EnvelopeMovementChoice
  = AllocateToEnvelope
  | MoveBetweenEnvelopes
  | ReturnToUnassigned

main :: IO ()
main = do
  arguments <- getArgs
  rootPath <- case arguments of
    [path] -> pure path
    _ -> die "Usage: h-kernel-editor-haskeline <household-root>"
  root <- case mkHouseholdRoot rootPath of
    Left err -> die ("Invalid household root: " <> show err)
    Right value -> pure value
  initial <- loadCanonicalHouseholdWriteSnapshot root
  snapshot <- case initial of
    Left errors -> die
      ("Failed to load canonical Household:\n"
        <> unlines (map show (NonEmpty.toList errors)))
    Right value -> pure value
  today <- localDay . zonedTimeToLocalTime <$> getZonedTime
  runInputT defaultSettings (dialogueLoop today root snapshot)

dialogueLoop
  :: Day
  -> HouseholdRoot
  -> HouseholdWriteSnapshot
  -> InputT IO ()
dialogueLoop today root snapshot = do
  outputStrLn ""
  choice <- chooseOne
    "What would you like to do?"
    [ ("Record an expense", RecordExpense)
    , ("Record income", RecordIncome)
    , ("Move money for Envelopes", ManageEnvelopeMoney)
    , ("Quit", QuitDialogue)
    ]
  case choice of
    Nothing -> pure ()
    Just QuitDialogue -> pure ()
    Just RecordExpense -> continueWith =<< recordDaily today root snapshot False
    Just RecordIncome -> continueWith =<< recordDaily today root snapshot True
    Just ManageEnvelopeMoney -> continueWith =<< envelopeDialogue today root snapshot
  where
    continueWith Nothing =
      outputStrLn "The Household could not be refreshed safely. Restart before writing again."
    continueWith (Just fresh) = dialogueLoop today root fresh

recordDaily
  :: Day
  -> HouseholdRoot
  -> HouseholdWriteSnapshot
  -> Bool
  -> InputT IO (Maybe HouseholdWriteSnapshot)
recordDaily today root snapshot isIncome = do
  let state = householdWriteSnapshotState snapshot
      journal = householdStateActualJournal state
      registry = householdStateAccountsRegistry state
      transactions =
        map actualTransactionEntryTransaction
          (actualJournalTransactionEntries journal)
      candidates = if isIncome then incomeAccountCandidates else dailyAccountCandidates
      toLabel = if isIncome then "Receive into" else "Category"
      fromLabel = if isIncome then "Income source" else "Pay from"
      toCandidates = candidates registry transactions SelectToAccount
      fromCandidates = candidates registry transactions SelectFromAccount
  outputStrLn ""
  outputStrLn (if isIncome then "Record income" else "Record expense")
  description <- promptRequired "Description: "
  case description of
    Nothing -> pure (Just snapshot)
    Just descriptionText -> do
      toAccount <- chooseAccount toLabel toCandidates
      case toAccount of
        Nothing -> pure (Just snapshot)
        Just selectedTo -> do
          fromAccount <- chooseAccount fromLabel fromCandidates
          case fromAccount of
            Nothing -> pure (Just snapshot)
            Just selectedFrom -> do
              amount <- promptActualAmount registry selectedFrom selectedTo
              case amount of
                Nothing -> pure (Just snapshot)
                Just amountText -> do
                  entryDay <- promptDay today
                  case entryDay of
                    Nothing -> pure (Just snapshot)
                    Just day -> do
                      let input = ActualAddInput
                            { addDateText = T.pack (show day)
                            , addDescriptionText = descriptionText
                            , addFromAccountText = accountName selectedFrom
                            , addToAccountText = accountName selectedTo
                            , addAmountText = amountText
                            }
                          preview = prepareActualAddPreviewFromResolvedJournal
                            (actualJournalValue journal)
                            (householdWriteSnapshotActualSource snapshot)
                            input
                      case preview of
                        ActualAddInputRejected err -> do
                          outputStrLn ("Input rejected: " <> show err)
                          pure (Just snapshot)
                        ActualAddCandidateRejected errors -> do
                          outputStrLn
                            ("Candidate rejected: "
                              <> show (NonEmpty.toList errors))
                          pure (Just snapshot)
                        ActualAddCandidateReady block -> do
                          outputPreview "Actual preview" block
                          confirmed <- confirmPublish
                          if not confirmed
                            then pure (Just snapshot)
                            else publishActual root snapshot block

promptActualAmount
  :: AccountRegistry
  -> Account
  -> Account
  -> InputT IO (Maybe Text)
promptActualAmount registry fromAccount toAccount =
  promptRequired prompt
  where
    prompt = case sharedDefaultCommodity registry fromAccount toAccount of
      Just commodity ->
        "Amount [" <> T.unpack (commodityCode commodity) <> "]: "
      Nothing -> "Amount (for example: 1200 JPY): "

publishActual
  :: HouseholdRoot
  -> HouseholdWriteSnapshot
  -> Text
  -> InputT IO (Maybe HouseholdWriteSnapshot)
publishActual root snapshot block = do
  let state = householdWriteSnapshotState snapshot
      path = householdActualJournalPath (householdStatePaths state)
      expected = householdWriteSnapshotActualSource snapshot
  result <- liftIO
    (publishActualBlockWithPathAdmission
      (\_ -> loadCanonicalHousehold root)
      path
      expected
      block)
  case result of
    Left err -> do
      outputStrLn ("Actual publication failed: " <> show err)
      refreshSnapshot root
    Right () -> do
      outputStrLn "Published Actual and re-admitted the Household."
      refreshSnapshot root

envelopeDialogue
  :: Day
  -> HouseholdRoot
  -> HouseholdWriteSnapshot
  -> InputT IO (Maybe HouseholdWriteSnapshot)
envelopeDialogue today root snapshot = do
  let state = householdWriteSnapshotState snapshot
      policy = householdStatePolicy state
      envelopeChoices = [EnvelopeChoice eid | eid <- householdEnvelopeOrder policy]
  movementChoice <- chooseOne
    "Envelope money:"
    [ ("Allocate unassigned money to an Envelope", AllocateToEnvelope)
    , ("Move money between Envelopes", MoveBetweenEnvelopes)
    , ("Return money from an Envelope to unassigned", ReturnToUnassigned)
    ]
  case movementChoice of
    Nothing -> pure (Just snapshot)
    Just AllocateToEnvelope -> do
      destination <- chooseEnvelope "Envelope to fund" envelopeChoices
      case destination of
        Nothing -> pure (Just snapshot)
        Just dest -> prepareEnvelopeMovement today root snapshot
          "allocate" Unallocated (Spendable (choiceEnvelopeId dest))
          (Just (choiceEnvelopeId dest))
    Just ReturnToUnassigned -> do
      source <- chooseEnvelope "Envelope to release" envelopeChoices
      case source of
        Nothing -> pure (Just snapshot)
        Just src -> prepareEnvelopeMovement today root snapshot
          "release" (Spendable (choiceEnvelopeId src)) Unallocated
          (Just (choiceEnvelopeId src))
    Just MoveBetweenEnvelopes -> do
      source <- chooseEnvelope "Move from Envelope" envelopeChoices
      case source of
        Nothing -> pure (Just snapshot)
        Just selectedSource -> do
          let destinations = filter
                ((/= choiceEnvelopeId selectedSource) . choiceEnvelopeId)
                envelopeChoices
          destination <- chooseEnvelope "Move to Envelope" destinations
          case destination of
            Nothing -> pure (Just snapshot)
            Just selectedDestination ->
              prepareEnvelopeMovement today root snapshot
                "move"
                (Spendable (choiceEnvelopeId selectedSource))
                (Spendable (choiceEnvelopeId selectedDestination))
                (Just (choiceEnvelopeId selectedDestination))

prepareEnvelopeMovement
  :: Day
  -> HouseholdRoot
  -> HouseholdWriteSnapshot
  -> Text
  -> EnvelopeEndpoint
  -> EnvelopeEndpoint
  -> Maybe EnvelopeId
  -> InputT IO (Maybe HouseholdWriteSnapshot)
prepareEnvelopeMovement today root snapshot memoVerb fromEndpoint toEndpoint maybeEnvelope = do
  let state = householdWriteSnapshotState snapshot
      envelopePolicy = householdStateEnvelopePolicy state
      registry = householdEnvelopeRegistry (householdStateEnvelopeHistory state)
      defaultMemo = memoVerb <> maybe "" ((" " <>) . envelopeIdText) maybeEnvelope
  amount <- promptPositiveAmount
  case amount of
    Nothing -> pure (Just snapshot)
    Just movementAmount -> do
      movementDay <- promptDay today
      case movementDay of
        Nothing -> pure (Just snapshot)
        Just day -> do
          memo <- promptWithDefault
            ("Memo [" <> T.unpack defaultMemo <> "]: ") defaultMemo
          case memo of
            Nothing -> pure (Just snapshot)
            Just movementMemo -> do
              case mkEnvelopeEntitlementTransfer day fromEndpoint toEndpoint movementAmount movementMemo of
                Left transferErr -> do
                  outputStrLn ("Invalid transfer: " <> show transferErr)
                  pure (Just snapshot)
                Right transfer ->
                  case prepareCurrentEntitlementTransferAppend
                      envelopePolicy
                      registry
                      (householdWriteSnapshotEntitlementSource snapshot)
                      transfer of
                    Left errors -> do
                      outputStrLn
                        ("Envelope movement rejected: "
                          <> show (NonEmpty.toList errors))
                      pure (Just snapshot)
                    Right preview -> do
                      outputPreview
                        "Envelope movement preview"
                        (entitlementCandidateBlock preview)
                      confirmed <- confirmPublish
                      if not confirmed
                        then pure (Just snapshot)
                        else publishEntitlement root snapshot preview

publishEntitlement
  :: HouseholdRoot
  -> HouseholdWriteSnapshot
  -> EntitlementTransferAppendPreview
  -> InputT IO (Maybe HouseholdWriteSnapshot)
publishEntitlement root snapshot preview = do
  let state = householdWriteSnapshotState snapshot
      path = householdEntitlementJournalPath (householdStatePaths state)
      expected = householdWriteSnapshotEntitlementSource snapshot
      intent = WriteIntent
        { targetFilePath = path
        , expectedOldBytes = ExpectedSource expected
        , candidateNewBytes = CandidateSource
            (entitlementCandidateCompleteSource preview)
        }
  result <- liftIO
    (publishWithPathAdmission
      (\_ -> loadCanonicalHousehold root)
      intent)
  case result of
    Left err -> do
      outputStrLn ("Envelope movement publication failed: " <> show err)
      refreshSnapshot root
    Right () -> do
      outputStrLn "Published Envelope movement and re-admitted the Household."
      refreshSnapshot root

chooseEnvelope
  :: String
  -> [EnvelopeChoice]
  -> InputT IO (Maybe EnvelopeChoice)
chooseEnvelope title choices =
  chooseOne title
    [ (T.unpack (envelopeIdText (choiceEnvelopeId choice)), choice)
    | choice <- choices
    ]

chooseAccount :: String -> [Account] -> InputT IO (Maybe Account)
chooseAccount title accounts =
  chooseOne title
    [(T.unpack (accountName account), account) | account <- accounts]

sharedDefaultCommodity
  :: AccountRegistry
  -> Account
  -> Account
  -> Maybe Commodity
sharedDefaultCommodity registry firstAccount secondAccount =
  case catMaybes (map defaultFor [firstAccount, secondAccount]) of
    [] -> Nothing
    commodity : rest
      | all (== commodity) rest -> Just commodity
      | otherwise -> Nothing
  where
    defaultFor account =
      declaredAccountDefaultCommodity =<<
        lookupAccountDeclaration account registry

promptPositiveAmount :: InputT IO (Maybe Amount)
promptPositiveAmount = do
  raw <- promptRequired "Amount (for example: 1200 JPY): "
  case raw of
    Nothing -> pure Nothing
    Just value -> case parseAmountText value of
      Left message -> outputStrLn (T.unpack message) >> promptPositiveAmount
      Right amount -> pure (Just amount)

parseAmountText :: Text -> Either Text Amount
parseAmountText input = do
  (quantityText, commodity) <- case T.words (T.strip input) of
    [quantityValue, commodityValue] -> do
      value <- either (const (Left "Invalid Commodity.")) Right
        (mkCommodity commodityValue)
      Right (quantityValue, value)
    _ -> Left "Amount must be a quantity followed by Commodity (for example: 1200 JPY)."
  quantity <- either (const (Left "Invalid quantity.")) Right
    (parseQuantity quantityText)
  if quantityToRational quantity <= 0
    then Left "Amount must be positive."
    else Right (mkAmount commodity quantity)

promptDay :: Day -> InputT IO (Maybe Day)
promptDay fallback = do
  raw <- getInputLine ("Date [" <> show fallback <> "]: ")
  case raw of
    Nothing -> pure Nothing
    Just value
      | null (words value) -> pure (Just fallback)
      | otherwise -> case readMaybe value of
          Just day -> pure (Just day)
          Nothing -> outputStrLn "Date must be YYYY-MM-DD." >> promptDay fallback

promptRequired :: String -> InputT IO (Maybe Text)
promptRequired prompt = do
  raw <- getInputLine prompt
  case raw of
    Nothing -> pure Nothing
    Just value
      | T.null (T.strip (T.pack value)) ->
          outputStrLn "A value is required." >> promptRequired prompt
      | otherwise -> pure (Just (T.strip (T.pack value)))

promptWithDefault :: String -> Text -> InputT IO (Maybe Text)
promptWithDefault prompt fallback = do
  raw <- getInputLine prompt
  pure $ case raw of
    Nothing -> Nothing
    Just value
      | T.null (T.strip (T.pack value)) -> Just fallback
      | otherwise -> Just (T.strip (T.pack value))

chooseOne :: String -> [(String, value)] -> InputT IO (Maybe value)
chooseOne title choices = do
  outputStrLn title
  mapM_ outputChoice (zip [1 :: Int ..] choices)
  raw <- getInputLine "> "
  case raw of
    Nothing -> pure Nothing
    Just value
      | T.toCaseFold (T.strip (T.pack value)) `elem` ["q", "quit", "cancel"] ->
          pure Nothing
      | otherwise -> case readMaybe value of
          Just index
            | index >= 1 && index <= length choices ->
                pure (Just (snd (choices !! (index - 1))))
          _ -> outputStrLn "Choose a number, or q to cancel." >> chooseOne title choices
  where
    outputChoice (index, (label, _)) =
      outputStrLn ("  " <> show index <> ". " <> label)

confirmPublish :: InputT IO Bool
confirmPublish = do
  raw <- getInputLine "Publish? [y/N] "
  pure $ case fmap (T.toCaseFold . T.strip . T.pack) raw of
    Just "y" -> True
    Just "yes" -> True
    _ -> False

outputPreview :: String -> Text -> InputT IO ()
outputPreview title block = do
  outputStrLn ""
  outputStrLn ("--- " <> title <> " ---")
  outputStrLn (T.unpack block)
  outputStrLn "-------------------------"

refreshSnapshot
  :: HouseholdRoot
  -> InputT IO (Maybe HouseholdWriteSnapshot)
refreshSnapshot root = do
  refreshed <- liftIO (loadCanonicalHouseholdWriteSnapshot root)
  case refreshed of
    Left errors -> do
      outputStrLn
        ("Household reload failed: " <> show (NonEmpty.toList errors))
      pure Nothing
    Right snapshot -> pure (Just snapshot)
