#!/usr/bin/env python3
from pathlib import Path
import re

lifecycle_path = Path('editor-src/HKernel/Editor/PlanLifecycle.hs')
lifecycle = lifecycle_path.read_text()

lifecycle = lifecycle.replace(
    'import Data.Char (isAsciiLower, isAsciiUpper, toLower)\n',
    '',
    1,
)
marker = 'import HKernel.Editor.SourceAppend (SourceBlock(..), appendSourceBlock)\n'
if marker not in lifecycle:
    raise SystemExit('PlanLifecycle SourceAppend import marker missing')
lifecycle = lifecycle.replace(
    marker,
    'import HKernel.Editor.PlanIdentity\n'
    '  ( descriptionPlanIdStem\n'
    '  , generateAvailablePlanId\n'
    '  )\n'
    + marker,
    1,
)

old_generation = '''slugify :: Text -> Text
slugify t =
  let
    mapped = T.map (\\c -> if isAsciiUpper c then toLower c else if isAsciiLower c || (c >= '0' && c <= '9') then c else '-') t
    collapsed = T.intercalate "-" (filter (not . T.null) (T.splitOn "-" mapped))
  in collapsed

generatePlanId
  :: Day
  -> Text
  -> Maybe Text
  -> [PlanId]
  -> Either PlanIdError PlanId
generatePlanId date desc mSeries existingIds = go 1
  where
    prefix = "plan-" <> T.pack (formatTime defaultTimeLocale "%Y-%m-%d" date) <> "-"
    suffix = case mSeries of
      Just series -> series
      Nothing ->
        let slug = slugify desc
        in if T.null slug then "plan" else slug
    base = prefix <> suffix

    candidateText candidateNumber
      | candidateNumber == 1 = base
      | candidateNumber < 10 =
          base <> "-0" <> T.pack (show candidateNumber)
      | otherwise = base <> "-" <> T.pack (show candidateNumber)

    go candidateNumber = do
      candidateId <- mkPlanId (candidateText candidateNumber)
      if candidateId `elem` existingIds
        then go (candidateNumber + 1)
        else Right candidateId

'''
if old_generation not in lifecycle:
    raise SystemExit('PlanLifecycle local generation block missing')
lifecycle = lifecycle.replace(old_generation, '', 1)

old_call = '''    Nothing -> first (pure . AddGeneratedIdError)
      (generatePlanId
        (addDate intent)
        (addDescription intent)
        (addSeries intent)
        existingPlanIds)
'''
new_call = '''    Nothing -> first (pure . AddGeneratedIdError)
      (generateAvailablePlanId
        (T.pack (formatTime defaultTimeLocale "%Y-%m-%d" (addDate intent)))
        (case addSeries intent of
          Just series -> series
          Nothing -> descriptionPlanIdStem (addDescription intent))
        existingPlanIds)
'''
if old_call not in lifecycle:
    raise SystemExit('PlanLifecycle generated ID call missing')
lifecycle = lifecycle.replace(old_call, new_call, 1)
lifecycle_path.write_text(lifecycle)

advance_path = Path('editor-src/HKernel/Editor/PlanCompleteAdvance.hs')
advance = advance_path.read_text()
advance = advance.replace(
    'import Data.Char (isAsciiLower, isAsciiUpper, toLower)\n',
    '',
    1,
)
marker = 'import HKernel.Editor.SourceAppend (SourceBlock(..), appendSourceBlock)\n'
if marker not in advance:
    raise SystemExit('PlanCompleteAdvance SourceAppend import marker missing')
advance = advance.replace(
    marker,
    'import HKernel.Editor.PlanIdentity\n'
    '  ( descriptionPlanIdStem\n'
    '  , generateAvailablePlanId\n'
    '  )\n'
    + marker,
    1,
)
advance = advance.replace('  , mkPlanId\n', '', 1)

old_call = '''        (generateSuccessorPlanId
          successorDate
          (transactionDescription transaction)
          (metadataValue "series" metadata)
          (map identifiedPlanId (planJournalTransactions planJournal)
            ++ map declaredCompletionPlanId
              (actualJournalCompletionDeclarations actualJournal)))
'''
new_call = '''        (generateAvailablePlanId
          (T.pack (show successorDate))
          (successorPlanIdStem
            (transactionDescription transaction)
            (metadataValue "series" metadata))
          (map identifiedPlanId (planJournalTransactions planJournal)
            ++ map declaredCompletionPlanId
              (actualJournalCompletionDeclarations actualJournal)))
'''
if old_call not in advance:
    raise SystemExit('successor generated ID call missing')
advance = advance.replace(old_call, new_call, 1)

old_generation = '''slugify :: Text -> Text
slugify textValue = T.intercalate "-" (filter (not . T.null) (T.splitOn "-" mapped))
  where
    mapped = T.map mapCharacter textValue
    mapCharacter character
      | isAsciiUpper character = toLower character
      | isAsciiLower character = character
      | character >= '0' && character <= '9' = character
      | otherwise = '-'

generateSuccessorPlanId :: Day -> Text -> Maybe Text -> [PlanId] -> Either PlanIdError PlanId
generateSuccessorPlanId date description maybeSeries existing = go 1
  where
    dateText = T.pack (show date)
    suffix = case maybeSeries of
      Just series | not (T.null (T.strip series)) -> T.strip series
      _ -> let slug = slugify description in if T.null slug then "plan" else slug
    base = "plan-" <> dateText <> "-" <> suffix
    candidate n
      | n == 1 = base
      | n < 10 = base <> "-0" <> T.pack (show n)
      | otherwise = base <> "-" <> T.pack (show n)
    go n = do
      planId <- mkPlanId (candidate n)
      if planId `elem` existing then go (n + 1) else Right planId

'''
if old_generation not in advance:
    raise SystemExit('PlanCompleteAdvance local generation block missing')
advance = advance.replace(old_generation, '', 1)

insert_after = '''nonBlankMetadataValue key metadata = do
  value <- metadataValue key metadata
  let stripped = T.strip value
  if T.null stripped then Nothing else Just stripped

'''
addition = '''successorPlanIdStem :: Text -> Maybe Text -> Text
successorPlanIdStem description maybeSeries = case maybeSeries of
  Just series | not (T.null (T.strip series)) -> T.strip series
  _ -> descriptionPlanIdStem description

'''
if insert_after not in advance:
    raise SystemExit('nonBlankMetadataValue block missing')
advance = advance.replace(insert_after, insert_after + addition, 1)
advance_path.write_text(advance)

cabal_path = Path('h-kernel.cabal')
cabal = cabal_path.read_text()
old = '''    other-modules:    HKernel.Editor.SourceAppend
'''
new = '''    other-modules:    HKernel.Editor.PlanIdentity
                    , HKernel.Editor.SourceAppend
'''
if old not in cabal:
    raise SystemExit('editor other-modules marker missing')
cabal_path.write_text(cabal.replace(old, new, 1))

# Add one focused collision characterization through the public Plan Add owner.
spec_path = Path('tests/EditorPlanLifecycleSpec.hs')
spec = spec_path.read_text()
old = '''        [ ("testPlanAddSuccess", testPlanAddSuccess)
        , ("testPlanAddUsesPlanAdmissionOnly", testPlanAddUsesPlanAdmissionOnly)
        , ("testPlanAddInvalidSeries", testPlanAddInvalidSeries)
'''
new = '''        [ ("testPlanAddSuccess", testPlanAddSuccess)
        , ("testPlanAddCollisionSuffix", testPlanAddCollisionSuffix)
        , ("testPlanAddUsesPlanAdmissionOnly", testPlanAddUsesPlanAdmissionOnly)
        , ("testPlanAddInvalidSeries", testPlanAddInvalidSeries)
'''
if old not in spec:
    raise SystemExit('Plan lifecycle result list marker missing')
spec = spec.replace(old, new, 1)

marker = '''testPlanAddUsesPlanAdmissionOnly :: Bool
'''
collision_test = '''testPlanAddCollisionSuffix :: Bool
testPlanAddCollisionSuffix =
  let collisionSource = planFixture <> T.unlines
        [ ""
        , "2023-01-02 reserved generated identity"
        , "  ; plan-id: plan-2023-01-03-test-dinner"
        , "  assets:bank  -100 JPY"
        , "  expenses:food  100 JPY"
        , ""
        , "2023-01-02 reserved generated identity 02"
        , "  ; plan-id: plan-2023-01-03-test-dinner-02"
        , "  assets:bank  -100 JPY"
        , "  expenses:food  100 JPY"
        ]
  in case preparePlanAdd collisionSource actualFixture (planAddIntent Nothing) of
      Right preview ->
        "plan-2023-01-03-test-dinner-03"
          `T.isInfixOf` addCandidateBlock preview
      Left err -> error (show err)

'''
if marker not in spec:
    raise SystemExit('Plan lifecycle insertion marker missing')
spec = spec.replace(marker, collision_test + marker, 1)
spec_path.write_text(spec)

for path in (lifecycle_path, advance_path):
    text = path.read_text()
    if 'slugify ::' in text or 'generateSuccessorPlanId' in text or 'generatePlanId\n' in text:
        raise SystemExit(f'stale local PlanId generator remains in {path}')

print('centralized description stem and collision generation without changing series/date policy')
