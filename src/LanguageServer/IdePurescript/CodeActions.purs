module LanguageServer.IdePurescript.CodeActions where

import Prelude

import Control.Monad.Except (runExcept)
import Data.Array (catMaybes, concat, filter, foldl, head, length, mapMaybe, nubByEq, singleton, sortWith, (:))
import Data.Either (Either(..), either)
import Data.Maybe (Maybe(..), fromMaybe, isJust, maybe)
import Data.Newtype (un)
import Data.Nullable as Nullable
import Data.String.Regex (regex)
import Data.String.Regex.Flags (noFlags)
import Data.Traversable (traverse)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Foreign (F, Foreign, readArray, readString)
import Foreign.Index ((!))
import Foreign.Object as Object
import IdePurescript.QuickFix (getReplacement, getTitle, isImport, isUnknownToken)
import IdePurescript.Regex (replace', test')
import LanguageServer.Console (log)
import IdePurescript.Regex (replace')
import LanguageServer.DocumentStore (getDocument)
import LanguageServer.Handlers (CodeActionParams, applyEdit)
import LanguageServer.IdePurescript.Assist (fixTypoActions)
import LanguageServer.IdePurescript.Build (positionToRange)
import LanguageServer.IdePurescript.Commands (Replacement, build, organiseImports, replaceAllSuggestions, replaceSuggestion, typedHole)
import LanguageServer.IdePurescript.Commands as Commands
import LanguageServer.IdePurescript.Types (ServerState(..))
import LanguageServer.Text (makeWorkspaceEdit)
import LanguageServer.TextDocument (TextDocument, getTextAtRange, getVersion)
import LanguageServer.Types (ClientCapabilities, CodeAction(..), CodeActionKind(..), CodeActionResult, Command(..), Diagnostic(..), DocumentStore, DocumentUri(DocumentUri), Position(Position), Range(Range), Settings, TextDocumentEdit(..), TextDocumentIdentifier(TextDocumentIdentifier), TextEdit(..), codeActionEmpty, codeActionResult, codeActionSource, codeActionSourceOrganizeImports, readRange, workspaceEdit)
import PscIde.Command (PscSuggestion(..), PursIdeInfo(..), RebuildError(..))

m = Nullable.toMaybe

codeActionLiteralsSupported :: ClientCapabilities -> Boolean
codeActionLiteralsSupported c = c #
  (_.textDocument >>> m) >>= (_.codeAction >>> m) >>= (_.codeActionLiteralSupport >>> m) # isJust

codeActionToCommand :: Maybe ClientCapabilities -> Either CodeAction Command -> Maybe CodeActionResult
codeActionToCommand capabilities action = codeActionResult <$>
  if supportsLiteral then
    Just action
  else
    either convert (Just <<< Right) action
  where
  supportsLiteral = maybe true codeActionLiteralsSupported capabilities
  convert (CodeAction { command }) | Just c <- m command = Just $ Right c
  convert _ = Nothing

getActions :: DocumentStore -> Settings -> ServerState -> CodeActionParams -> Aff (Array CodeActionResult)
getActions documents settings state@(ServerState { diagnostics, conn: Just conn, clientCapabilities }) { textDocument, range, context } =
  case Object.lookup (un DocumentUri $ docUri) diagnostics of
    Just errs -> mapMaybe (codeActionToCommand clientCapabilities) <$> do
      liftEffect$ log conn $ show clientCapabilities
      liftEffect$ log conn $ "Literals supported: " <> show (codeActionLiteralsSupported <$> clientCapabilities)
      
      codeActions <- traverse commandForCode errs
      pure $
        (map Right $ catMaybes $ map asCommand errs)
        <> (map Right $ fixAllCommand "Apply all suggestions" errs)
        <> (allImportSuggestions errs)
        <> (map Right $ concat codeActions)
        <> organiseImports
    _ -> pure []
  where
    docUri = _.uri $ un TextDocumentIdentifier textDocument

    asCommand error@(RebuildError { position: Just position, errorCode })
      | Just { replacement, range: replaceRange } <- getReplacementRange error
      , intersects (positionToRange position) range = do
      Just $ replaceSuggestion (getTitle errorCode) docUri replacement replaceRange
    asCommand _ = Nothing

    organiseImports = [ Left $ commandAction (CodeActionKind $ "source.organizeImports") (Commands.organiseImports docUri) ]

    getReplacementRange (RebuildError { position: Just position, suggestion: Just (PscSuggestion { replacement, replaceRange }) }) =
      Just $ { replacement, range: range' }
      where
      range' = positionToRange $ fromMaybe position replaceRange
    getReplacementRange _ = Nothing


    allImportSuggestions errs = map (Left <<< commandAction codeActionEmpty) $
      -- fixAllCommand "Organize Imports" (filter (\(RebuildError { errorCode, position }) -> isImport errorCode ) errs)
        fixAllCommand "Apply all import suggestions" (filter (\(RebuildError { errorCode, position }) -> isImport errorCode) errs)
        -- TODO this seems to filter out all but 1 error?
          -- maybe false (\pos -> intersects (positionToRange pos) range) position) errs)

    fixAllCommand text rebuildErrors = if length replacements > 0 then [ replaceAllSuggestions text docUri replacements ] else [ ]
      where
      replacements :: Array { range :: Range, replacement :: String }
      replacements = removeOverlaps $ sortWith _.range $ nubByEq eq $ mapMaybe getReplacementRange rebuildErrors

    removeOverlaps :: Array { range :: Range, replacement :: String } -> Array { range :: Range, replacement :: String }
    removeOverlaps = foldl go []
      where
      go [] x = [x] 
      go acc x@{range: Range { start }} 
        | Just ({range: Range { end: lastEnd }}) <- head acc
        , lastEnd < start
        = x:acc
      go acc _ = acc

    commandForCode err@(RebuildError { position: Just position, errorCode }) | intersects (positionToRange position) range =
      case errorCode of
        "ModuleNotFound" -> pure [ build ]
        "HoleInferredType" -> case err of
          RebuildError { pursIde: Just (PursIdeInfo { name, completions }) } ->
            pure $ singleton $ typedHole name docUri (positionToRange position) completions
          _ -> pure []
        x | isUnknownToken x
          , { startLine, startColumn } <- position ->
            fixTypoActions documents settings state docUri (startLine-1) (startColumn-1)
        _ -> pure []
    commandForCode _ = pure []

    intersects (Range { start, end }) (Range { start: start', end: end' }) = start <= end' && start' <= end

getActions _ _ _ _ = pure []

commandAction kind c@(Command { title }) = CodeAction { title, kind, isPreferred: false, edit: Nullable.toNullable Nothing
                                                      , command: Nullable.toNullable $ Just c }
  
  -- codeActionSourceOrganizeImports
  -- codeActionEmpty
 



afterEnd :: Range -> Range
afterEnd (Range { end: end@(Position { line, character }) }) =
  Range
    { start: end
    , end: Position { line, character: character + 10 }
    }

toNextLine :: Range -> Range
toNextLine (Range { start, end: end@(Position { line, character }) }) =
  Range
    { start
    , end: Position { line: line+1, character: 0 }
    }

onReplaceSuggestion :: DocumentStore -> Settings -> ServerState -> Array Foreign -> Aff Unit
onReplaceSuggestion docs config (ServerState { conn, clientCapabilities }) args =
  case conn, args of
    Just conn', [ uri', replacement', range' ]
      | Right uri <- runExcept $ readString uri'
      , Right replacement <- runExcept $ readString replacement'
      , Right range <- runExcept $ readRange range'
      -> do
        doc <- liftEffect $ getDocument docs (DocumentUri uri)
        version <- liftEffect $ getVersion doc
        TextEdit { range: range'', newText } <- getReplacementEdit doc { replacement, range }
        let edit = makeWorkspaceEdit clientCapabilities (DocumentUri uri) version range'' newText

        -- TODO: Check original & expected text ?
        void $ applyEdit conn' edit
    _, _ -> pure unit


getReplacementEdit :: TextDocument -> Replacement -> Aff TextEdit
getReplacementEdit doc { replacement, range } = do
  origText <- liftEffect $ getTextAtRange doc range
  afterText <- liftEffect $ replace' (regex "\n$" noFlags) "" <$> getTextAtRange doc (afterEnd range)

  let newText = getReplacement replacement afterText

  let range' = if newText == "" && afterText == "" then
                toNextLine range
                else
                range
  pure $ TextEdit { range: range', newText }

onReplaceAllSuggestions :: DocumentStore -> Settings -> ServerState -> Array Foreign -> Aff Unit
onReplaceAllSuggestions docs config (ServerState { conn, clientCapabilities }) args =
  case conn, args of
    Just conn', [ uri', suggestions' ]
      | Right uri <- runExcept $ readString uri'
      , Right suggestions <- runExcept $ readArray suggestions' >>= traverse readSuggestion
      -> do
          doc <- liftEffect $ getDocument docs (DocumentUri uri)
          version <- liftEffect $ getVersion doc
          edits <- traverse (getReplacementEdit doc) suggestions
          void $ applyEdit conn' $ workspaceEdit clientCapabilities
            [ TextDocumentEdit
              { textDocument: TextDocumentIdentifier { uri: DocumentUri uri, version }
              , edits
              }
            ]
    _, _ -> pure unit

readSuggestion :: Foreign -> F Replacement
readSuggestion o = do
  replacement <- o ! "replacement" >>= readString
  range <- o ! "range" >>= readRange
  pure $ { replacement, range }

