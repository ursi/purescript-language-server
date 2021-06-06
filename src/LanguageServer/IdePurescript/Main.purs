module LanguageServer.IdePurescript.Main (main) where

import Prelude

import Control.Monad.Except (runExcept)
import Control.Promise (Promise)
import Control.Promise as Promise
import Data.Array (length, (!!), (\\))
import Data.Array as Array
import Data.Either (Either(..), either)
import Data.Foldable (for_, or, sequence_)
import Data.Maybe (Maybe(..), fromMaybe, isNothing, maybe, maybe')
import Data.Newtype (over, un, unwrap)
import Data.Nullable (toMaybe, toNullable)
import Data.Profunctor.Strong (first)
import Data.String (Pattern(..), contains)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Aff (Aff, Milliseconds(..), apathize, attempt, delay, forkAff, launchAff_, runAff_, try)
import Effect.Aff.AVar (AVar)
import Effect.Aff.AVar as AVar
import Effect.Class (liftEffect)
import Effect.Console as Console
import Effect.Ref (Ref)
import Effect.Ref as Ref
import Foreign (Foreign, unsafeToForeign)
import Foreign.JSON (parseJSON)
import Foreign.Object (Object)
import Foreign.Object as Object
import IdePurescript.Modules (getModulesForFileTemp, initialModulesState)
import IdePurescript.PscIdeServer (ErrorLevel(..), Notify)
import LanguageServer.Console (error, info, log, warn)
import LanguageServer.DocumentStore (getDocument, onDidChangeContent, onDidOpenDocument, onDidSaveDocument)
import LanguageServer.Handlers (onCodeAction, onCompletion, onDefinition, onDidChangeConfiguration, onDidChangeWatchedFiles, onDocumentSymbol, onExecuteCommand, onFoldingRanges, onDocumentFormatting, onHover, onReferences, onShutdown, onWorkspaceSymbol, publishDiagnostics, sendDiagnosticsBegin, sendDiagnosticsEnd)
import LanguageServer.IdePurescript.Assist (addClause, caseSplit, fillTypedHole, fixTypo)
import LanguageServer.IdePurescript.Build (collectByFirst, fullBuild, getDiagnostics)
import LanguageServer.IdePurescript.CodeActions (getActions, onReplaceAllSuggestions, onReplaceSuggestion)
import LanguageServer.IdePurescript.Commands (addClauseCmd, addCompletionImportCmd, addModuleImportCmd, buildCmd, caseSplitCmd, cmdName, commands, fixTypoCmd, getAvailableModulesCmd, organiseImportsCmd, replaceAllSuggestionsCmd, replaceSuggestionCmd, restartPscIdeCmd, searchCmd, startPscIdeCmd, stopPscIdeCmd, typedHoleExplicitCmd)
import LanguageServer.IdePurescript.Completion (getCompletions)
import LanguageServer.IdePurescript.Config as Config
import LanguageServer.IdePurescript.FoldingRanges (getFoldingRanges)
import LanguageServer.IdePurescript.Formatting (getFormattedDocument)
import LanguageServer.IdePurescript.Imports (addCompletionImport, addModuleImport', getAllModules, organiseImports)
import LanguageServer.IdePurescript.References (getReferences)
import LanguageServer.IdePurescript.Search (search)
import LanguageServer.IdePurescript.Server as Server
import LanguageServer.IdePurescript.Symbols (getDefinition, getDocumentSymbols, getWorkspaceSymbols)
import LanguageServer.IdePurescript.Tooltips (getTooltips)
import LanguageServer.IdePurescript.Types (ServerState(..), CommandHandler)
import LanguageServer.Setup (InitParams(..), getConfiguration, initConnection, initDocumentStore)
import LanguageServer.TextDocument (TextDocument, getText, getUri)
import LanguageServer.Types (Connection, Diagnostic, DocumentStore, DocumentUri(..), FileChangeType(..), FileChangeTypeCode(..), FileEvent(..), Settings, TextDocumentIdentifier(..), intToFileChangeType)
import LanguageServer.Uri (filenameToUri, uriToFilename)
import LanguageServer.Window (showError, showWarningWithActions)
import Node.Encoding as Encoding
import Node.FS.Aff as FS
import Node.FS.Sync as FSSync
import Node.Path (resolve)
import Node.Process as Process
import PscIde.Command (RebuildError(..))

defaultServerState :: ServerState
defaultServerState = ServerState
  { port: Nothing
  , deactivate: pure unit
  , root: Nothing
  , conn: Nothing
  , modules: initialModulesState
  , modulesFile: Nothing
  , buildQueue: Object.empty
  , diagnostics: Object.empty
  , clientCapabilities: Nothing
  }

type CmdLineArguments =
  { config :: Maybe String
  , filename :: Maybe String
  }

-- | Parses command line arguments  passed to process.argv
parseArgs :: Array String -> Maybe CmdLineArguments
parseArgs allArgs = go 0 defaultArgs
  where
  args = Array.drop 2 allArgs

  defaultArgs = { config: Nothing, filename: Nothing }

  go i c =
    case args !! i of
      Just "--config" -> case args !! (i+1) of
        Just conf -> go (i+2) (c { config = Just conf })
        Nothing -> Nothing
      Just "--log" -> case args !! (i+1) of
        Just filename -> go (i+2) (c { filename = Just filename })
        Nothing -> Nothing
      -- stdio etc
      Just _ -> go (i+1) c
      Nothing -> Just c

updateModules ::
  Ref ServerState -> DocumentStore -> DocumentUri -> Aff (Maybe ServerState)
updateModules state documents uri =
  liftEffect (Ref.read state) >>= case _ of
    ServerState { port: Just port, modulesFile }
      | modulesFile /= Just uri -> do
      text <- liftEffect $ getDocument documents uri >>= getText
      path <- liftEffect $ uriToFilename uri
      modules <- getModulesForFileTemp port path text
      s <- liftEffect
        $ Ref.modify
        (over ServerState (_ { modules = modules, modulesFile = Just uri }))
        state
      pure $ Just s
    _ -> pure Nothing

getCon :: Ref ServerState -> Effect Unit
getCon state = do
  mbConn <- getConnection state
  case mbConn of
    Just conn -> log conn "x"
    _ -> pure unit

mkRunHandler ::
  Ref Foreign ->
  Ref ServerState ->
  DocumentStore ->
  String -> forall a b.
  (b -> Maybe DocumentUri) ->
  (Settings -> ServerState -> b -> Aff a) ->
  b ->
  Effect (Promise a)
mkRunHandler
  config state documents
  handlerName docUri f b =
  Promise.fromAff do
    mbConn <- liftEffect $ getConnection state
    c <- liftEffect $ Ref.read config
    ms <- maybe (pure Nothing) (updateModules state documents) (docUri b)
    s <- maybe' (\_ -> liftEffect $ Ref.read state) pure ms
    f c s b

-- | Extracts document uri value
getTextDocUri :: forall r.
  { textDocument :: TextDocumentIdentifier | r } -> Maybe DocumentUri
getTextDocUri = (Just <<< _.uri <<< un TextDocumentIdentifier <<< _.textDocument)

-- | This mutes buggy warning coming from purs-ide, just to keep the output clean.
-- | The issue: https://github.com/purescript/purescript/issues/3377
muteReexportsWarn ::
  (Connection → String → Effect Unit) -> Connection -> String -> Effect Unit
muteReexportsWarn logFn con str =
  if str # contains (Pattern "Failed to resolve reexports for Type.")
    then pure unit
    else logFn con str


mkLogError ::
  Maybe String -> Ref ServerState -> Notify
mkLogError logFile state l s = do
    (_.conn <$> unwrap <$> Ref.read state) >>=
      maybe (pure unit) (flip case l of
          Success -> log
          Info -> muteReexportsWarn info
          Warning -> warn
          Error -> error
        s)
    case logFile of
      Just filename ->
        FSSync.appendTextFile Encoding.UTF8 filename ("[" <> show l <> "] " <> s <> "\n")
      Nothing -> pure unit

-- | Stops IDE server
mkStopPscIdeServer :: Ref ServerState -> Notify -> Aff Unit
mkStopPscIdeServer state logError = do
  quit <- liftEffect (_.deactivate <$> unwrap <$> Ref.read state)
  quit
  liftEffect do
    Ref.modify_
      (over ServerState $ _ { port = Nothing, deactivate = pure unit })
      state
    logError Success "Stopped IDE server"

-- | Reads workspace root from state
getWorkspaceRoot :: Ref ServerState -> Effect String
getWorkspaceRoot state = do
  root <- (_.root <<< unwrap) <$> Ref.read state
  maybe Process.cwd pure root

-- | Read connection from state
getConnection :: Ref ServerState -> Effect (Maybe Connection)
getConnection state = do
  (_.conn <<< unwrap) <$> Ref.read state

-- | Read port from state
getPort :: Ref ServerState -> Effect (Maybe Int)
getPort state = do
  (_.port <<< unwrap) <$> Ref.read state

-- | Builds documents in queue (which where opened on server startup)
buildDocumentsInQueue :: Ref Foreign ->
  Connection -> Ref ServerState ->
  (ErrorLevel -> String -> Effect Unit) ->
  Effect Unit
buildDocumentsInQueue config conn state logError = do
  queue <- (_.buildQueue <<< unwrap) <$> Ref.read state
  let docs = Object.values $ queue
  launchAff_
    $ sequence_
    $ map (rebuildAndSendDiagnostics config conn state logError) docs

-- | Tries to start IDE server at workspace root
mkStartPscIdeServer :: Ref Foreign -> Connection -> Ref ServerState -> Notify -> Aff Unit
mkStartPscIdeServer config conn state logError = do
  let workspaceRoot = getWorkspaceRoot state
  liftEffect $ logError Info "Starting IDE server"
  rootPath <- liftEffect workspaceRoot
  settings <- liftEffect $ Ref.read config
  startRes <- Server.startServer' settings rootPath logError logError
  Server.retry logError 6 case startRes of
    { port: Just port, quit } -> do
      Server.loadAll port >>= case _ of
        Left msg -> liftEffect
          $ logError Info $ "Non-fatal error loading modules: " <> msg
        _ -> pure unit

      liftEffect
        $ Ref.modify_
        (over ServerState $ _ { port = Just port, deactivate = quit })
        state
    _ -> pure unit
  liftEffect $ buildDocumentsInQueue config conn state logError

connect :: Ref ServerState -> Effect Connection
connect state =
  initConnection commands
  $ \({ params: InitParams { rootPath, rootUri, capabilities }, conn })
  -> do
    Process.argv >>= \args -> log conn $ "Starting with args: " <> show args
    root <- case toMaybe rootUri, toMaybe rootPath of
      Just uri, _ -> Just <$> uriToFilename uri
      _, Just path -> pure $ Just path
      Nothing, Nothing -> pure Nothing
    workingRoot <- maybe Process.cwd pure root
    Ref.modify_
      (over ServerState $ _
        { root = Just workingRoot
        , clientCapabilities = Just capabilities
        })
      state
    (\(Tuple dir root') ->
      log conn ("Starting with cwd: " <> dir <> " and using root path: " <> root'))
        =<< Tuple <$> Process.cwd <*> pure workingRoot
    Ref.modify_ (over ServerState $ _ { conn = Just conn }) state

-- | Starts full build
buildProject ::
  Connection -> Ref ServerState -> Notify ->
  DocumentStore -> Foreign -> ServerState -> Array Foreign -> Aff Unit
buildProject
  conn state logError
  docs c s arguments = do
  let workspaceRoot = getWorkspaceRoot state

  liftEffect $ sendDiagnosticsBegin conn

  fullBuild logError docs c s arguments >>= case _ of
    Right { pscErrors, diagnostics } ->
      liftEffect do
        log conn $ "Built with " <> (show $ length pscErrors) <> " issues"
        pscErrorsMap <- collectByFirst <$> traverse (\e@(RebuildError { filename }) -> do
          projectRoot <- workspaceRoot
          filename' <- traverse (resolve [ projectRoot ]) filename
          uri <- maybe (pure Nothing) (\f -> Just <$> un DocumentUri <$> filenameToUri f) filename'
          pure $ Tuple uri e)
            pscErrors
        prevErrors <- _.diagnostics <$> un ServerState <$> Ref.read state
        let nonErrorFiles :: Array String
            nonErrorFiles = Object.keys prevErrors \\ Object.keys pscErrorsMap
        log conn $ "Removing old diagnostics for: " <> show nonErrorFiles
        for_ (map DocumentUri nonErrorFiles) \uri -> publishDiagnostics conn { uri, diagnostics: [] }

        Ref.write (over ServerState (_ { diagnostics = pscErrorsMap }) s) state
        for_ (Object.toUnfoldable diagnostics :: Array (Tuple String (Array Diagnostic))) \(Tuple filename fileDiagnostics) -> do
          uri <- filenameToUri filename
          log conn $ "Publishing diagnostics for: " <> show uri <> " (" <> show filename <> ")"
          publishDiagnostics conn { uri, diagnostics: fileDiagnostics }
    Left err ->
      liftEffect do error conn err
                    showError conn err
  liftEffect $ sendDiagnosticsEnd conn

launchAffLog' :: forall a. Notify -> Aff a -> Effect Unit
launchAffLog' logError =
  runAff_ (either (logError Error <<< show) (const $ pure unit))

-- | Starts PscIDE Server if autoStart enabled in config.
autoStartPcsIdeServer ::
  Ref Foreign ->
  Connection ->
  Ref ServerState ->
  Notify ->
  DocumentStore ->
  Aff Unit
autoStartPcsIdeServer config conn state logError documents  = do
    let workspaceRoot = getWorkspaceRoot state
    let launchAffLog = launchAffLog' logError
    let startPscIdeServer = mkStartPscIdeServer config conn state logError
    let resolvePath p = workspaceRoot >>= \root -> resolve [ root ] p
    -- Ensure we only run once
    c <- liftEffect $ Ref.read config
    when (Config.autoStartPscIde c) $ do
      startPscIdeServer

      outputDir <- liftEffect
        $ resolvePath $ Config.effectiveOutputDirectory c

      hasPackageFile <- or <$> traverse (FS.exists <=< liftEffect  <<< resolvePath)
        ["bower.json", "psc-package.json", "spago.dhall", "flake.nix", "shell.nix"]

      envIdeSources <- Server.getEnvPursIdeSources

      when (not hasPackageFile && isNothing envIdeSources) do
        liftEffect $ showError conn
          ( "It doesn't look like the workspace root is a PureScript project"
            <> "(has bower.json/psc-package.json/spago.dhall/flake.nix/shell.nix)."
            <> "The PureScript project should be opened as a root workspace folder."
          )

      exists <- FS.exists outputDir
      unless exists $ liftEffect $ launchAffLog do
        let message = "Output directory does not exist at '" <> outputDir <> "'"
        liftEffect $ info conn message

        let buildOption = "Build project"
        action <- showWarningWithActions conn
          ( message
            <> ". Ensure project is built, or check configuration of output directory"
            <> " and build command."
          )
          [ buildOption ]
        when (action == Just buildOption) do
          s <- liftEffect $ Ref.read state
          buildProject conn state logError documents c s []

-- | Builds module and provides diagnostics
rebuildAndSendDiagnostics ::
  Ref Foreign ->
  Connection ->
  Ref ServerState ->
  Notify ->
  TextDocument ->
  Aff Unit
rebuildAndSendDiagnostics config conn state logError document = do
  let uri = getUri document
  c <- liftEffect $ Ref.read config
  s <- liftEffect $ Ref.read state
  --organizeDiagnostics <- organiseImportsDiagnostic s logError document
  when (Config.fastRebuild c) do
    liftEffect $ sendDiagnosticsBegin conn
    { pscErrors, diagnostics } <- getDiagnostics uri c s
    filename <- liftEffect $ uriToFilename uri
    let fileDiagnostics = fromMaybe [] $ Object.lookup filename diagnostics
    liftEffect do
      log conn
        $ "Built with "
          <> show (length fileDiagnostics)
          <> "/"
          <> show (length pscErrors)
          <> " issues for file: "
          <> show filename
          <> ", all diagnostic files: "
          <> show (Object.keys diagnostics)

      let nonFileDiagnostics = Object.delete filename diagnostics
      when (Object.size nonFileDiagnostics > 0) do
        log conn $ "Unmatched diagnostics: " <> show nonFileDiagnostics
      Ref.write (over ServerState (\s1 -> s1 {
        diagnostics = Object.insert (un DocumentUri uri) pscErrors (s1.diagnostics)
      , modulesFile = Nothing -- Force reload of modules on next request
      }) s) state
      publishDiagnostics conn
        { uri
        , diagnostics: fileDiagnostics -- <> organizeDiagnostics
        }
      sendDiagnosticsEnd conn

-- | Puts event handlers
handleEvents ::
  Ref Foreign ->
  Connection ->
  Ref ServerState ->
  DocumentStore -> Notify -> Effect Unit
handleEvents config conn state documents logError = do
  let runHandler = mkRunHandler config state documents
      stopPscIdeServer = mkStopPscIdeServer state logError
      launchAffLog  = launchAffLog' logError

  onCompletion conn $ runHandler
    "onCompletion" getTextDocUri (getCompletions documents)

  -- Handles go to definition
  onDefinition conn $ runHandler
    "onDefinition" getTextDocUri (getDefinition documents)

  onDocumentSymbol conn $ runHandler
    "onDocumentSymbol" getTextDocUri getDocumentSymbols

  onWorkspaceSymbol conn $ runHandler
    "onWorkspaceSymbol" (const Nothing) getWorkspaceSymbols

  onFoldingRanges conn $ runHandler
    "onFoldingRanges" getTextDocUri (getFoldingRanges documents)

  onDocumentFormatting conn $ runHandler
    "onDocumentFormatting" getTextDocUri (getFormattedDocument logError documents)

  onReferences conn $ runHandler
    "onReferences" getTextDocUri (getReferences documents)

  onHover conn $ runHandler
    "onHover" getTextDocUri (getTooltips documents)

  onCodeAction conn $ runHandler
    "onCodeAction" getTextDocUri (getActions documents)

  onShutdown conn $ Promise.fromAff stopPscIdeServer

  onDidChangeWatchedFiles conn $ \{ changes } -> do
    for_ changes \(FileEvent { uri, "type": FileChangeTypeCode n }) -> do
      case intToFileChangeType n of
        Just CreatedChangeType ->
          log conn $ "Created "
            <> un DocumentUri uri
            <> " - full build may be required"
        Just DeletedChangeType ->
          log conn $ "Deleted "
            <> un DocumentUri uri
            <> " - full build may be required"

        _ -> pure unit

  onDidChangeContent documents $ \{ document } -> do
    Ref.modify_ (over ServerState (_ { modulesFile = Nothing })) state

  -- On document opened rebuild it,
  -- or place it in a queue if no IDE server started
  onDidOpenDocument documents \{ document } -> launchAffLog do
    mbPort <- liftEffect $ getPort state
    case mbPort of
      Just p -> rebuildAndSendDiagnostics config conn state logError document
      _ -> do
        let uri = (un DocumentUri $ getUri document)
        liftEffect $
          Ref.modify_ (over ServerState (\st -> st
          { buildQueue = Object.insert uri document (st.buildQueue)
          })) state

  onDidSaveDocument documents \{ document } -> launchAffLog do
    rebuildAndSendDiagnostics config conn state logError document


handleConfig ::
  Ref Foreign ->
  Connection ->
  Ref ServerState ->
  DocumentStore ->
  Maybe Foreign -> Notify ->  Aff Unit
handleConfig config conn state documents cmdLineConfig logError =  do
  let launchAffLog  = launchAffLog' logError

  gotConfig :: AVar Unit <- AVar.empty

  let setConfig :: String -> Foreign -> Aff Unit
      setConfig source newConfig = do
        liftEffect do
          log conn $ "Got new config (" <> source <> ")"
          Ref.write newConfig config
        AVar.tryPut unit gotConfig >>= case _ of
          true -> pure unit
          false -> liftEffect $ log conn "Not starting server, already started"

  liftEffect $ onDidChangeConfiguration conn $ \{settings} ->
    launchAffLog $ setConfig "client push" settings

  _ <- forkAff do
    -- Ensure we only run once
    AVar.read gotConfig
    autoStartPcsIdeServer config conn state logError documents

  -- 1. Config on command line - go immediately
  maybe (pure unit) (setConfig "command line") cmdLineConfig

  delay (Milliseconds 50.0)
  -- 2. Config may be pushed immediately
  got1 <- AVar.isFilled <$> AVar.status gotConfig
  unless got1 do
    -- 3. Fetch config via pull (waited 50ms as at least in vscode, not ready immediately)
    initialConfig <- attempt $ getConfiguration conn
    case initialConfig of
      Right ic ->
        setConfig "by request" ic
      Left error -> do
        liftEffect $ log conn $ "Failed to request settings: " <> show error
        -- 4. Wait some time longer for possible config push, then proceed with no config
        delay (Milliseconds 200.0)
        got2 <- AVar.isFilled <$> AVar.status gotConfig
        unless got2 do
          liftEffect $ logError Warning "Proceeding with no config received"
          void $ AVar.tryPut unit gotConfig


-- | Registers commands handlers
handleCommands ::
  Ref Foreign ->
  Connection ->
  Ref ServerState ->
  DocumentStore ->
  Notify ->
  Effect Unit
handleCommands config conn state documents logError = do
  let onBuild = buildProject conn state logError
      stopPscIdeServer = mkStopPscIdeServer state logError
      startPscIdeServer = mkStartPscIdeServer config conn state logError
      restartPscIdeServer = do
        apathize stopPscIdeServer
        startPscIdeServer

  let noResult = unsafeToForeign $ toNullable Nothing
  let voidHandler :: forall a. CommandHandler a -> CommandHandler Foreign
      voidHandler h d c s a =
        try (h d c s a) >>= case _ of
          Left err -> do
            liftEffect $ logError Error $ show err
            pure noResult
          Right _ -> pure noResult
      simpleHandler h d c s a = h $> noResult

  let handlers :: Object (CommandHandler Foreign)
      handlers = Object.fromFoldable $ first cmdName <$>
        [ Tuple caseSplitCmd $ voidHandler caseSplit
        , Tuple addClauseCmd $ voidHandler addClause
        , Tuple replaceSuggestionCmd $ voidHandler onReplaceSuggestion
        , Tuple replaceAllSuggestionsCmd $ voidHandler onReplaceAllSuggestions
        , Tuple buildCmd $ voidHandler onBuild
        , Tuple addCompletionImportCmd $ addCompletionImport logError
        , Tuple addModuleImportCmd $ voidHandler $ addModuleImport' logError
        , Tuple organiseImportsCmd $ organiseImports logError
        , Tuple startPscIdeCmd $ simpleHandler startPscIdeServer
        , Tuple stopPscIdeCmd $ simpleHandler stopPscIdeServer
        , Tuple restartPscIdeCmd $ simpleHandler restartPscIdeServer
        , Tuple getAvailableModulesCmd $ getAllModules logError
        , Tuple searchCmd $ search
        , Tuple fixTypoCmd $ fixTypo logError
        , Tuple typedHoleExplicitCmd $ voidHandler $ fillTypedHole logError
        ]

  onExecuteCommand conn $ \{ command, arguments } -> Promise.fromAff do
    c <- liftEffect $ Ref.read config
    s <- liftEffect $ Ref.read state
    case Object.lookup command handlers of
      Just handler -> handler documents c s arguments
      Nothing -> do
        liftEffect $ error conn $ "Unknown command: " <> command
        pure noResult

-- | main function parses the CLI arguments
-- | and calls main' with parsed args to launch effects
main :: Effect Unit
main = do
  maybeArgs <- parseArgs <$> Process.argv
  args' <- case maybeArgs of
    Nothing -> do
      Console.error "Error parsing args"
      Process.exit 1
    Just args -> do
      maybe (pure unit) (flip (FSSync.writeTextFile Encoding.UTF8) "Starting logging...\n") args.filename
      let config' = case args.config of
                      Just c -> either (const Nothing) Just $ runExcept $ parseJSON c
                      Nothing -> Nothing
      pure (args { config = config' } )
  main' args'

main' ::
  { config :: Maybe Foreign
  , filename :: Maybe String
  } -> Effect Unit
main' { filename: logFile, config: cmdLineConfig } = do

  state <- Ref.new defaultServerState
  config <- Ref.new (unsafeToForeign {})

  conn <- connect state
  documents <- initDocumentStore conn

  let logError = mkLogError logFile state

  handleEvents config conn state documents logError
  handleCommands config conn state documents logError

  launchAff_ $ handleConfig config conn state documents cmdLineConfig logError

  log conn "PureScript Language Server started"
