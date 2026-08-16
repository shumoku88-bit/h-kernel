{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad.IO.Class (liftIO)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import qualified Data.Set as Set
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
import HKernel.Editor.BudgetMovementAppend
  ( BudgetJournalMovementAppendPreview(..)
  , prepareCurrentBudgetJournalMovementAppend
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
import HKernel.Household.BudgetMovement (HouseholdBudgetMovement(..))
import HKernel.Household.Policy
  ( HouseholdPolicy
  , householdAllocationEnvelopes
  , householdEnvelopeOrder
  , householdUnassignedBudgetAccounts
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

data EnvelopeChoice = EnvelopeChoice
  { choiceEnvelopeId :: EnvelopeId
  , choiceAllocationAccount :: Account
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
  choices <- case currentEnvelopeChoices policy of
    Left message -> outputStrLn (T.unpack message) >> pure Nothing
    Right values -> pure (Just values)
  case choices of
    Nothing -> pure (Just snapshot)
    Just envelopeChoices -> do
      movementChoice <- chooseOne
        "Envelope money:"
        [ ("Allocate unassigned money to an Envelope", AllocateToEnvelope)
        , ("Move money between Envelopes", MoveBetweenEnvelopes)
        , ("Return money from an Envelope to unassigned", ReturnToUnassigned)
        ]
      case movementChoice of
        Nothing -> pure (Just snapshot)
        Just AllocateToEnvelope -> do
          fromAccount <- chooseUnassigned policy
          destination <- chooseEnvelope "Envelope to fund" envelopeChoices
          prepareEnvelopeMovement today root snapshot
            "allocate" fromAccount (choiceAllocationAccount <$> destination)
            (choiceEnvelopeId <$> destination)
        Just ReturnToUnassigned -> do
          source <- chooseEnvelope "Envelope to release" envelopeChoices
          toAccount <- chooseUnassigned policy
          prepareEnvelopeMovement today root snapshot
            "release" (choiceAllocationAccount <$> source) toAccount
            (choiceEnvelopeId <$> source)
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
                    (Just (choiceAllocationAccount selectedSource))
                    (Just (choiceAllocationAccount selectedDestination))
                    (Just (choiceEnvelopeId selectedDestination))

prepareEnvelopeMovement
  :: Day
  -> HouseholdRoot
  -> HouseholdWriteSnapshot
  -> Text
  -> Maybe Account
  -> Maybe Account
  -> Maybe EnvelopeId
  -> InputT IO (Maybe HouseholdWriteSnapshot)
prepareEnvelopeMovement today root snapshot memoVerb maybeFrom maybeTo maybeEnvelope =
  case (maybeFrom, maybeTo) of
    (Just fromAccount, Just toAccount) -> do
      let state = householdWriteSnapshotState snapshot
          registry = householdStateAccountsRegistry state
          policy = householdStatePolicy state
          defaultMemo = memoVerb <> maybe "" ((" " <>) . envelopeIdText) maybeEnvelope
      amount <- promptPositiveAmount registry fromAccount toAccount
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
                  let movement = HouseholdBudgetMovement
                        { householdBudgetMovementDate = day
                        , householdBudgetMovementMemo = movementMemo
                        , householdBudgetMovementFrom = fromAccount
                        , householdBudgetMovementTo = toAccount
                        , householdBudgetMovementAmount = movementAmount
                        }
                  case prepareCurrentBudgetJournalMovementAppend
                      registry
                      policy
                      (householdWriteSnapshotBudgetSource snapshot)
                      movement of
                    Left errors -> do
                      outputStrLn
                        ("Envelope movement rejected: "
                          <> show (NonEmpty.toList errors))
                      pure (Just snapshot)
                    Right preview -> do
                      outputPreview
                        "Envelope movement preview"
                        (budgetJournalCandidateBlock preview)
                      confirmed <- confirmPublish
                      if not confirmed
                        then pure (Just snapshot)
                        else publishBudget root snapshot preview
    _ -> pure (Just snapshot)

publishBudget
  :: HouseholdRoot
  -> HouseholdWriteSnapshot
  -> BudgetJournalMovementAppendPreview
  -> InputT IO (Maybe HouseholdWriteSnapshot)
publishBudget root snapshot preview = do
  let state = householdWriteSnapshotState snapshot
      path = householdBudgetJournalPath (householdStatePaths state)
      expected = householdWriteSnapshotBudgetSource snapshot
      intent = WriteIntent
        { targetFilePath = path
        , expectedOldBytes = ExpectedSource expected
        , candidateNewBytes = CandidateSource
            (budgetJournalCandidateCompleteSource preview)
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

currentEnvelopeChoices
  :: HouseholdPolicy
  -> Either Text [EnvelopeChoice]
currentEnvelopeChoices policy =
  traverse resolve (householdEnvelopeOrder policy)
  where
    coordinates = Map.toList (householdAllocationEnvelopes policy)
    resolve envelope = case
        [ account
        | (account, mappedEnvelope) <- coordinates
        , mappedEnvelope == envelope
        ] of
      [account] -> Right (EnvelopeChoice envelope account)
      [] -> Left
        ("Current Envelope has no allocation coordinate: "
          <> envelopeIdText envelope)
      _ -> Left
        ("Current Envelope has duplicate allocation coordinates: "
          <> envelopeIdText envelope)

chooseEnvelope
  :: String
  -> [EnvelopeChoice]
  -> InputT IO (Maybe EnvelopeChoice)
chooseEnvelope title choices =
  chooseOne title
    [ (T.unpack (envelopeIdText (choiceEnvelopeId choice)), choice)
    | choice <- choices
    ]

chooseUnassigned :: HouseholdPolicy -> InputT IO (Maybe Account)
chooseUnassigned policy = case
    Set.toAscList (householdUnassignedBudgetAccounts policy) of
  [] -> outputStrLn "No current unassigned Budget Account is configured." >> pure Nothing
  [account] -> pure (Just account)
  accounts -> chooseAccount "Unassigned coordinate" accounts

chooseAccount :: String -> [Account] -> InputT IO (Maybe Account)
chooseAccount title accounts =
  chooseOne title
    [(T.unpack (accountName account), account) | account <- accounts]

sharedDefaultCommodity
  :: AccountRegistry
  -> Account
  -> Account
  -> Maybe Commodity
sharedDefaultCommodity registry first second =
  case catMaybes (map defaultFor [first, second]) of
    [] -> Nothing
    commodity : rest
      | all (== commodity) rest -> Just commodity
      | otherwise -> Nothing
  where
    defaultFor account =
      declaredAccountDefaultCommodity =<<
        lookupAccountDeclaration account registry

promptPositiveAmount
  :: AccountRegistry
  -> Account
  -> Account
  -> InputT IO (Maybe Amount)
promptPositiveAmount registry fromAccount toAccount = do
  let defaultCommodity = sharedDefaultCommodity registry fromAccount toAccount
      prompt = case defaultCommodity of
        Just commodity ->
          "Amount [" <> T.unpack (commodityCode commodity) <> "]: "
        Nothing -> "Amount (for example: 1200 JPY): "
  raw <- promptRequired prompt
  case raw of
    Nothing -> pure Nothing
    Just value -> case parseAmountText defaultCommodity value of
      Left message -> outputStrLn (T.unpack message)
        >> promptPositiveAmount registry fromAccount toAccount
      Right amount -> pure (Just amount)

parseAmountText :: Maybe Commodity -> Text -> Either Text Amount
parseAmountText defaultCommodity input = do
  (quantityText, commodity) <- case T.words (T.strip input) of
    [quantityValue] -> case defaultCommodity of
      Just value -> Right (quantityValue, value)
      Nothing -> Left "Commodity is required for these Accounts."
    [quantityValue, commodityValue] -> do
      value <- either (const (Left "Invalid Commodity.")) Right
        (mkCommodity commodityValue)
      Right (quantityValue, value)
    _ -> Left "Amount must be a quantity, optionally followed by Commodity."
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
