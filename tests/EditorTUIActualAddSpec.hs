{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Exit (exitFailure, exitSuccess)

import HKernel.Account (AccountType(..), accountName, mkAccount)
import HKernel.Editor.ActualAppend
  ( ActualAddInput(..)
  , ActualAddInputError(..)
  , ActualAddWriteFailure(..)
  , ActualAddWriteOutcome(..)
  , ActualEditIntent(..)
  , ActualMultiAddInput(..)
  , ActualMultiAddInputError(..)
  , ActualMultiAddPreview(..)
  , ActualPostingInput(..)
  , buildActualAddIntent
  , buildActualAddIntentWithRegistry
  , buildActualMultiAddIntentWithRegistry
  , classifyActualAddWriteResult
  , prepareActualMultiAddPreviewFromResolvedJournal
  )
import HKernel.Editor.ActualWriter (WriteError(..))
import HKernel.Editor.Interaction.ActualAdd
  ( AccountSelectionTarget(..)
  , ActualMultiAddState(..)
  , appendActualMultiPosting
  , dailyAccountCandidates
  , filterDailyAccountCandidates
  , filterMultiAccountCandidates
  , groupAccountCandidates
  , incomeAccountCandidates
  , initialActualAddInputForDay
  , initialActualMultiAddStateForDay
  , multiAccountCandidates
  , removeSelectedActualMultiPosting
  , resizeActualMultiPostings
  , selectActualAddAccount
  , selectActualMultiPosting
  , selectedActualMultiPosting
  , setActualMultiDateText
  , setSelectedActualMultiAccount
  , setSelectedActualMultiAccountText
  , setSelectedActualMultiAmount
  , stepAccountCandidate
  )
import HKernel.Editor.TransactionBlock (IntentPosting(..))
import HKernel.Journal
  ( journalAccountRegistry
  , journalTransactions
  , parseJournal
  )
import HKernel.Money (commodityCode, renderQuantity)

main :: IO ()
main = do
  source <- TIO.readFile "tests/fixtures/editor/actual-add.journal"
  let results =
        [ ("positive magnitude builds balanced typed intent", testPositiveMagnitude)
        , ("negative magnitude is rejected", testNegativeMagnitude)
        , ("zero magnitude is rejected", testZeroMagnitude)
        , ("amount shape is explicit without registry", testAmountShape)
        , ("daily amount infers canonical default commodity", testDefaultCommodityInference source)
        , ("conflicting defaults fail before candidate creation", testConflictingDefaults)
        , ("missing defaults fail before candidate creation", testMissingDefaults)
        , ("daily input starts on supplied day", testInitialDay)
        , ("expense candidates are typed and recent-first", testExpenseCandidates)
        , ("payment candidates are typed, recent-first, and retain unused Accounts", testPaymentCandidates)
        , ("income receiving candidates are Asset-only and recent-first", testIncomeReceivingCandidates)
        , ("income source candidates are Income-only", testIncomeSourceCandidates)
        , ("daily income reuses ordinary balanced posting direction", testIncomeDirection)
        , ("candidate groups use typed meaning and preserve order within groups", testCandidateGroups)
        , ("candidate stepping enters and wraps without selector state", testCandidateStepping)
        , ("candidate search is case-insensitive and order-preserving", testCandidateSearch)
        , ("empty candidate search preserves recent-first list", testEmptyCandidateSearch)
        , ("from Account selection updates input", testFromSelection)
        , ("daily Account reselection preserves the rest of the draft", testDailyReselectionPreservesDraft)
        , ("multi input builds signed three-posting intent", testMultiBuild)
        , ("multi input requires at least three postings", testMultiRequiresThree)
        , ("multi input rejects zero posting with row coordinate", testMultiRejectsZero)
        , ("balanced multi input prepares one canonical candidate", testMultiBalancedPreview)
        , ("unbalanced multi input is rejected by transaction admission", testMultiUnbalancedRejected)
        , ("multi interaction starts with three blank posting rows", testMultiInteractionInitial)
        , ("multi interaction accepts ordinary date text editing", testMultiInteractionDateText)
        , ("multi interaction resizes posting rows without shortcut keys", testMultiInteractionResize)
        , ("multi interaction appends and selects a new posting row", testMultiInteractionAppend)
        , ("multi interaction never removes below three posting rows", testMultiInteractionMinimum)
        , ("multi interaction updates only the selected posting", testMultiInteractionSelectedEdit)
        , ("multi interaction edits Account text without a picker", testMultiInteractionAccountText)
        , ("multi Account candidates are canonical and recent-first", testMultiAccountCandidates)
        , ("multi Account search is case-insensitive", testMultiAccountSearch)
        , ("successful write result is observable", testWriteSuccess)
        , ("stale write result is observable", testWriteStale)
        , ("restored admission failure is recoverable", testWriteRecovered)
        , ("failed restoration requires verification", testWriteRecoveryFailure)
        , ("filesystem failure is observable", testWriteFileIOFailure)
        ]
  mapM_ print results
  if all snd results then exitSuccess else exitFailure

validInput :: ActualAddInput
validInput = ActualAddInput
  { addDateText = "2026-08-05"
  , addDescriptionText = "Groceries"
  , addFromAccountText = "assets:cash"
  , addToAccountText = "expenses:food"
  , addAmountText = "100 JPY"
  }

incomeInput :: ActualAddInput
incomeInput = ActualAddInput
  { addDateText = "2026-08-08"
  , addDescriptionText = "Pension"
  , addFromAccountText = "income:pension"
  , addToAccountText = "assets:bank"
  , addAmountText = "100"
  }

testPositiveMagnitude :: Bool
testPositiveMagnitude = case buildActualAddIntent validInput of
  Right intent -> case NonEmpty.toList (intentPostings intent) of
    [destination, source] ->
      accountName (intentAccount destination) == "expenses:food"
        && renderQuantity (intentQuantity destination) == "100"
        && accountName (intentAccount source) == "assets:cash"
        && renderQuantity (intentQuantity source) == "-100"
        && intentMetadata intent == []
    _ -> False
  Left _ -> False

testNegativeMagnitude :: Bool
testNegativeMagnitude =
  buildActualAddIntent (validInput { addAmountText = "-100 JPY" })
    == Left ActualAddAmountMustBePositive

testZeroMagnitude :: Bool
testZeroMagnitude =
  buildActualAddIntent (validInput { addAmountText = "0 JPY" })
    == Left ActualAddAmountMustBePositive

testAmountShape :: Bool
testAmountShape =
  buildActualAddIntent (validInput { addAmountText = "100" })
    == Left ActualAddInvalidAmountShape

testDefaultCommodityInference :: T.Text -> Bool
testDefaultCommodityInference source =
  case parseJournal source of
    Left _ -> False
    Right journal ->
      case buildActualAddIntentWithRegistry
          (journalAccountRegistry journal)
          (validInput { addAmountText = "100" }) of
        Left _ -> False
        Right intent -> case NonEmpty.toList (intentPostings intent) of
          [destination, sourcePosting] ->
            showCommodity destination == "JPY"
              && showCommodity sourcePosting == "JPY"
          _ -> False
  where
    showCommodity = maybe "" commodityCode . intentCommodity

testConflictingDefaults :: Bool
testConflictingDefaults =
  case parseJournal conflictingDefaultSource of
    Left _ -> False
    Right journal ->
      buildActualAddIntentWithRegistry
        (journalAccountRegistry journal)
        (validInput { addAmountText = "100" })
        == Left ActualAddConflictingDefaultCommodity

testMissingDefaults :: Bool
testMissingDefaults =
  case parseJournal missingDefaultSource of
    Left _ -> False
    Right journal ->
      buildActualAddIntentWithRegistry
        (journalAccountRegistry journal)
        (validInput { addAmountText = "100" })
        == Left ActualAddMissingDefaultCommodity

conflictingDefaultSource :: T.Text
conflictingDefaultSource = T.unlines
  [ "account assets:cash"
  , "  type: Asset"
  , "  commodity: JPY"
  , "account expenses:food"
  , "  type: Expense"
  , "  commodity: USD"
  ]

missingDefaultSource :: T.Text
missingDefaultSource = T.unlines
  [ "account assets:cash"
  , "  type: Asset"
  , "account expenses:food"
  , "  type: Expense"
  ]

testInitialDay :: Bool
testInitialDay =
  addDateText (initialActualAddInputForDay (read "2026-08-08"))
    == "2026-08-08"

testExpenseCandidates :: Bool
testExpenseCandidates =
  case parseJournal candidateSource of
    Left _ -> False
    Right journal ->
      map accountName
        (dailyAccountCandidates
          (journalAccountRegistry journal)
          (journalTransactions journal)
          SelectToAccount)
        == ["expenses:books", "expenses:food"]

testPaymentCandidates :: Bool
testPaymentCandidates =
  case parseJournal candidateSource of
    Left _ -> False
    Right journal ->
      map accountName
        (dailyAccountCandidates
          (journalAccountRegistry journal)
          (journalTransactions journal)
          SelectFromAccount)
        == ["liabilities:card", "assets:cash", "assets:bank"]

testIncomeReceivingCandidates :: Bool
testIncomeReceivingCandidates =
  case parseJournal candidateSource of
    Left _ -> False
    Right journal ->
      map accountName
        (incomeAccountCandidates
          (journalAccountRegistry journal)
          (journalTransactions journal)
          SelectToAccount)
        == ["assets:cash", "assets:bank"]

testIncomeSourceCandidates :: Bool
testIncomeSourceCandidates =
  case parseJournal candidateSource of
    Left _ -> False
    Right journal ->
      map accountName
        (incomeAccountCandidates
          (journalAccountRegistry journal)
          (journalTransactions journal)
          SelectFromAccount)
        == ["income:pension"]

testIncomeDirection :: Bool
testIncomeDirection =
  case parseJournal candidateSource of
    Left _ -> False
    Right journal ->
      case buildActualAddIntentWithRegistry
          (journalAccountRegistry journal) incomeInput of
        Left _ -> False
        Right intent -> case NonEmpty.toList (intentPostings intent) of
          [destination, source] ->
            accountName (intentAccount destination) == "assets:bank"
              && renderQuantity (intentQuantity destination) == "100"
              && accountName (intentAccount source) == "income:pension"
              && renderQuantity (intentQuantity source) == "-100"
          _ -> False

testCandidateGroups :: Bool
testCandidateGroups =
  case parseJournal candidateSource of
    Left _ -> False
    Right journal ->
      let registry = journalAccountRegistry journal
          candidates = dailyAccountCandidates registry
            (journalTransactions journal) SelectFromAccount
          groups =
            [ (accountType, map accountName accounts)
            | (accountType, accounts) <- groupAccountCandidates registry candidates
            ]
      in groups
          == [ (Asset, ["assets:cash", "assets:bank"])
             , (Liability, ["liabilities:card"])
             ]

testCandidateStepping :: Bool
testCandidateStepping =
  case parseJournal candidateSource of
    Left _ -> False
    Right journal ->
      let registry = journalAccountRegistry journal
          recent = dailyAccountCandidates registry
            (journalTransactions journal) SelectFromAccount
          candidates = concatMap snd (groupAccountCandidates registry recent)
          stepped offset current = accountName <$> stepAccountCandidate offset current candidates
      in stepped 1 "" == Just "assets:cash"
          && stepped 1 "assets:cash" == Just "assets:bank"
          && stepped 1 "assets:bank" == Just "liabilities:card"
          && stepped 1 "liabilities:card" == Just "assets:cash"
          && stepped (-1) "assets:cash" == Just "liabilities:card"

testCandidateSearch :: Bool
testCandidateSearch =
  case parseJournal candidateSource of
    Left _ -> False
    Right journal ->
      let candidates =
            dailyAccountCandidates
              (journalAccountRegistry journal)
              (journalTransactions journal)
              SelectToAccount
      in map accountName (filterDailyAccountCandidates "BOOK" candidates)
          == ["expenses:books"]

testEmptyCandidateSearch :: Bool
testEmptyCandidateSearch =
  case parseJournal candidateSource of
    Left _ -> False
    Right journal ->
      let candidates =
            dailyAccountCandidates
              (journalAccountRegistry journal)
              (journalTransactions journal)
              SelectFromAccount
      in filterDailyAccountCandidates "  " candidates == candidates

candidateSource :: T.Text
candidateSource = T.unlines
  [ "account assets:bank"
  , "  type: Asset"
  , "  commodity: JPY"
  , "account assets:cash"
  , "  type: Asset"
  , "  commodity: JPY"
  , "account liabilities:card"
  , "  type: Liability"
  , "  commodity: JPY"
  , "account expenses:books"
  , "  type: Expense"
  , "  commodity: JPY"
  , "account expenses:food"
  , "  type: Expense"
  , "  commodity: JPY"
  , "account income:pension"
  , "  type: Income"
  , "  commodity: JPY"
  , ""
  , "2026-08-06 groceries"
  , "  expenses:food  100 JPY"
  , "  assets:cash  -100 JPY"
  , ""
  , "2026-08-07 books"
  , "  expenses:books  200 JPY"
  , "  liabilities:card  -200 JPY"
  ]

testFromSelection :: Bool
testFromSelection = case mkAccount "assets:cash" of
  Left _ -> False
  Right account ->
    let selected = selectActualAddAccount SelectFromAccount account validInput
    in addFromAccountText selected == "assets:cash"
        && addDateText selected == addDateText validInput
        && addDescriptionText selected == addDescriptionText validInput
        && addToAccountText selected == addToAccountText validInput
        && addAmountText selected == addAmountText validInput

testDailyReselectionPreservesDraft :: Bool
testDailyReselectionPreservesDraft =
  case (mkAccount "expenses:books", mkAccount "expenses:food") of
    (Right books, Right food) ->
      let once = selectActualAddAccount SelectToAccount books validInput
          corrected = selectActualAddAccount SelectToAccount food once
      in addDateText corrected == addDateText validInput
          && addDescriptionText corrected == addDescriptionText validInput
          && addFromAccountText corrected == addFromAccountText validInput
          && addAmountText corrected == addAmountText validInput
          && addToAccountText corrected == "expenses:food"
    _ -> False

multiSource :: T.Text
multiSource = T.unlines
  [ "account assets:cash"
  , "  type: Asset"
  , "  commodity: JPY"
  , "account expenses:food"
  , "  type: Expense"
  , "  commodity: JPY"
  , "account expenses:books"
  , "  type: Expense"
  , "  commodity: JPY"
  ]

multiInput :: ActualMultiAddInput
multiInput = ActualMultiAddInput
  { multiAddDateText = "2026-08-08"
  , multiAddDescriptionText = "Split purchase"
  , multiAddPostings =
      ActualPostingInput "expenses:food" "600"
        NonEmpty.:| [ ActualPostingInput "expenses:books" "150"
                    , ActualPostingInput "assets:cash" "-750"
                    ]
  }

expectedMultiBlock :: T.Text
expectedMultiBlock = T.unlines
  [ "2026-08-08 Split purchase"
  , "  expenses:food  600 JPY"
  , "  expenses:books  150 JPY"
  , "  assets:cash  -750 JPY"
  ]

testMultiBuild :: Bool
testMultiBuild =
  case parseJournal multiSource of
    Left _ -> False
    Right journal ->
      case buildActualMultiAddIntentWithRegistry
          (journalAccountRegistry journal) multiInput of
        Left _ -> False
        Right intent ->
          map renderPosting (NonEmpty.toList (intentPostings intent))
            == [ ("expenses:food", "600", "JPY")
               , ("expenses:books", "150", "JPY")
               , ("assets:cash", "-750", "JPY")
               ]
  where
    renderPosting posting =
      ( accountName (intentAccount posting)
      , renderQuantity (intentQuantity posting)
      , maybe "" commodityCode (intentCommodity posting)
      )

testMultiRequiresThree :: Bool
testMultiRequiresThree =
  case parseJournal multiSource of
    Left _ -> False
    Right journal ->
      buildActualMultiAddIntentWithRegistry
        (journalAccountRegistry journal)
        (multiInput
          { multiAddPostings =
              ActualPostingInput "expenses:food" "600"
                NonEmpty.:| [ActualPostingInput "assets:cash" "-600"]
          })
        == Left ActualMultiAddNeedsAtLeastThreePostings

testMultiRejectsZero :: Bool
testMultiRejectsZero =
  case parseJournal multiSource of
    Left _ -> False
    Right journal ->
      buildActualMultiAddIntentWithRegistry
        (journalAccountRegistry journal)
        (multiInput
          { multiAddPostings =
              ActualPostingInput "expenses:food" "600"
                NonEmpty.:| [ ActualPostingInput "expenses:books" "0"
                            , ActualPostingInput "assets:cash" "-600"
                            ]
          })
        == Left (ActualMultiAddZeroQuantity 2)

testMultiBalancedPreview :: Bool
testMultiBalancedPreview =
  case parseJournal multiSource of
    Left _ -> False
    Right journal ->
      prepareActualMultiAddPreviewFromResolvedJournal journal multiSource multiInput
        == ActualMultiAddCandidateReady expectedMultiBlock

testMultiUnbalancedRejected :: Bool
testMultiUnbalancedRejected =
  case parseJournal multiSource of
    Left _ -> False
    Right journal ->
      case prepareActualMultiAddPreviewFromResolvedJournal
          journal
          multiSource
          (multiInput
            { multiAddPostings =
                ActualPostingInput "expenses:food" "600"
                  NonEmpty.:| [ ActualPostingInput "expenses:books" "150"
                              , ActualPostingInput "assets:cash" "-700"
                              ]
            }) of
        ActualMultiAddCandidateRejected _ -> True
        _ -> False

testMultiInteractionInitial :: Bool
testMultiInteractionInitial =
  let state = initialActualMultiAddStateForDay (read "2026-08-08")
      input = actualMultiAddInput state
      rows = NonEmpty.toList (multiAddPostings input)
  in multiAddDateText input == "2026-08-08"
      && length rows == 3
      && all (== ActualPostingInput "" "") rows
      && actualMultiSelectedPosting state == 0

testMultiInteractionDateText :: Bool
testMultiInteractionDateText =
  let state = setActualMultiDateText "2026-08-07"
        (initialActualMultiAddStateForDay (read "2026-08-08"))
  in multiAddDateText (actualMultiAddInput state) == "2026-08-07"

testMultiInteractionResize :: Bool
testMultiInteractionResize =
  let initial = initialActualMultiAddStateForDay (read "2026-08-08")
      fiveRows = resizeActualMultiPostings 5 initial
      selectedLast = selectActualMultiPosting 4 fiveRows
      reduced = resizeActualMultiPostings 3 selectedLast
  in length (NonEmpty.toList (multiAddPostings (actualMultiAddInput fiveRows))) == 5
      && length (NonEmpty.toList (multiAddPostings (actualMultiAddInput reduced))) == 3
      && actualMultiSelectedPosting reduced == 2

testMultiInteractionAppend :: Bool
testMultiInteractionAppend =
  let state = appendActualMultiPosting
        (initialActualMultiAddStateForDay (read "2026-08-08"))
  in length (NonEmpty.toList (multiAddPostings (actualMultiAddInput state))) == 4
      && actualMultiSelectedPosting state == 3

testMultiInteractionMinimum :: Bool
testMultiInteractionMinimum =
  let initial = initialActualMultiAddStateForDay (read "2026-08-08")
      unchanged = removeSelectedActualMultiPosting initial
      fourRows = appendActualMultiPosting initial
      reduced = removeSelectedActualMultiPosting fourRows
  in unchanged == initial
      && length (NonEmpty.toList (multiAddPostings (actualMultiAddInput reduced))) == 3
      && actualMultiSelectedPosting reduced == 2

testMultiInteractionSelectedEdit :: Bool
testMultiInteractionSelectedEdit = case mkAccount "expenses:books" of
  Left _ -> False
  Right account ->
    let initial = initialActualMultiAddStateForDay (read "2026-08-08")
        selected = selectActualMultiPosting 1 initial
        withAccount = setSelectedActualMultiAccount account selected
        withAmount = setSelectedActualMultiAmount "150" withAccount
        rows = NonEmpty.toList (multiAddPostings (actualMultiAddInput withAmount))
    in selectedActualMultiPosting withAmount
        == ActualPostingInput "expenses:books" "150"
        && rows !! 0 == ActualPostingInput "" ""
        && rows !! 2 == ActualPostingInput "" ""

testMultiInteractionAccountText :: Bool
testMultiInteractionAccountText =
  let initial = initialActualMultiAddStateForDay (read "2026-08-08")
      selected = selectActualMultiPosting 2 initial
      changed = setSelectedActualMultiAccountText "assets:cash" selected
  in selectedActualMultiPosting changed
      == ActualPostingInput "assets:cash" ""

testMultiAccountCandidates :: Bool
testMultiAccountCandidates =
  case parseJournal candidateSource of
    Left _ -> False
    Right journal ->
      map accountName
        (multiAccountCandidates
          (journalAccountRegistry journal)
          (journalTransactions journal))
        == [ "expenses:books"
           , "liabilities:card"
           , "expenses:food"
           , "assets:cash"
           , "assets:bank"
           , "income:pension"
           ]

testMultiAccountSearch :: Bool
testMultiAccountSearch =
  case parseJournal candidateSource of
    Left _ -> False
    Right journal ->
      let candidates = multiAccountCandidates
            (journalAccountRegistry journal)
            (journalTransactions journal)
      in map accountName (filterMultiAccountCandidates "PENSION" candidates)
          == ["income:pension"]

testWriteSuccess :: Bool
testWriteSuccess =
  classifyActualAddWriteResult
    (Right () :: Either (WriteError ()) ())
    == ActualAddWriteSucceeded

testWriteStale :: Bool
testWriteStale =
  classifyActualAddWriteResult
    (Left StaleFile :: Either (WriteError ()) ())
    == ActualAddWriteStale

testWriteRecovered :: Bool
testWriteRecovered =
  classifyActualAddWriteResult
    (Left
      (PostAdmissionFailed
        { failedSourceError = "synthetic" NonEmpty.:| []
        , restoredFromBackup = True
        }) :: Either (WriteError String) ())
    == ActualAddWriteRecovered ActualAddPostAdmissionFailure

testWriteRecoveryFailure :: Bool
testWriteRecoveryFailure =
  classifyActualAddWriteResult
    (Left
      (PostPublishReadFailed
        { failedReadMessage = "synthetic"
        , restoredFromBackup = False
        }) :: Either (WriteError ()) ())
    == ActualAddWriteFailed ActualAddPostPublishReadFailure

testWriteFileIOFailure :: Bool
testWriteFileIOFailure =
  classifyActualAddWriteResult
    (Left (FileIOError "synthetic") :: Either (WriteError ()) ())
    == ActualAddWriteFileIOFailed