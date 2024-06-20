{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}

module OptEnvConf.Run
  ( runSettingsParser,
    runParser,
    runParserComplete,
    runParserOn,
    internalParser,
    unrecognisedOptions,
  )
where

import Autodocodec
import Control.Arrow (left)
import Control.Monad.Reader hiding (Reader, reader, runReader)
import Control.Monad.State
import Data.Aeson ((.:?))
import qualified Data.Aeson as JSON
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.Types as JSON
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..), (<|))
import qualified Data.List.NonEmpty as NE
import Data.Maybe
import Data.Set (Set)
import qualified Data.Set as S
import Data.Traversable
import Data.Version
import OptEnvConf.Args (Args (..), Dashed (..), Opt (..))
import qualified OptEnvConf.Args as Args
import OptEnvConf.Completion
import OptEnvConf.Doc
import OptEnvConf.EnvMap (EnvMap (..))
import qualified OptEnvConf.EnvMap as EnvMap
import OptEnvConf.Error
import OptEnvConf.Lint
import OptEnvConf.Parser
import OptEnvConf.Reader
import OptEnvConf.Setting
import OptEnvConf.Validation
import Path
import System.Environment (getArgs, getEnvironment, getProgName)
import System.Exit
import System.IO
import Text.Colour
import Text.Colour.Capabilities.FromEnv

runSettingsParser :: (HasParser a) => Version -> IO a
runSettingsParser version = runParser version settingsParser

runParser :: Version -> Parser a -> IO a
runParser version p = do
  args <- getArgs
  let argMap = Args.parse args
  envVars <- EnvMap.parse <$> getEnvironment

  case lintParser p of
    Just errs -> do
      tc <- getTerminalCapabilitiesFromHandle stderr
      hPutChunksLocaleWith tc stderr $ renderLintErrors errs
      exitFailure
    Nothing -> do
      let p' = internalParser version p
      let docs = parserDocs p'
      errOrResult <-
        runParserComplete
          p'
          argMap
          envVars
          Nothing
      case errOrResult of
        Left errs -> do
          tc <- getTerminalCapabilitiesFromHandle stderr
          hPutChunksLocaleWith tc stderr $ renderErrors errs
          exitFailure
        Right i -> case i of
          ShowHelp -> do
            progname <- getProgName
            tc <- getTerminalCapabilitiesFromHandle stdout
            hPutChunksLocaleWith tc stdout $ renderHelpPage progname docs
            exitSuccess
          ShowVersion -> do
            progname <- getProgName
            tc <- getTerminalCapabilitiesFromHandle stdout
            hPutChunksLocaleWith tc stdout $ renderVersionPage progname version
            exitSuccess
          RenderMan -> do
            progname <- getProgName
            tc <- getTerminalCapabilitiesFromHandle stdout
            hPutChunksLocaleWith tc stdout $ renderManPage progname version docs
            exitSuccess
          BashCompletionScript progPath -> do
            progname <- getProgName
            generateBashCompletionScript progPath progname
            exitSuccess
          BashCompletionQuery index ws -> do
            runBashCompletionQuery p' index ws
            exitSuccess
          ParsedNormally a -> pure a

-- Internal structure to help us do what the framework
-- is supposed to.
data Internal a
  = ShowHelp
  | ShowVersion
  | RenderMan
  | BashCompletionScript (Path Abs File)
  | BashCompletionQuery !Int ![String]
  | ParsedNormally a

internalParser :: Version -> Parser a -> Parser (Internal a)
internalParser version p =
  choice
    [ setting
        [ switch ShowHelp,
          short 'h',
          long "help",
          help "Show this help text"
        ],
      setting
        [ switch ShowVersion,
          short 'v',
          long "version",
          help $ "Output version information: " <> showVersion version
        ],
      setting
        [ switch RenderMan,
          long "render-man-page",
          hidden,
          help "Show this help text"
        ],
      BashCompletionScript
        <$> mapIO
          parseAbsFile
          ( setting
              [ option,
                reader str,
                long "bash-completion-script",
                hidden,
                help "Render the bash completion script"
              ]
          ),
      BashCompletionQuery
        <$> setting
          [ option,
            reader auto,
            long "bash-completion-index",
            hidden,
            help "The index between the arguments where completion was invoked."
          ]
        <*> many
          ( setting
              [ option,
                reader str,
                long "bash-completion-word",
                hidden,
                help "The words (arguments) that have already been typed"
              ]
          ),
      ParsedNormally <$> p
    ]

-- 'runParserOn' _and_ 'unrecognisedOptions'
runParserComplete ::
  Parser a ->
  Args ->
  EnvMap ->
  Maybe JSON.Object ->
  IO (Either (NonEmpty ParseError) a)
runParserComplete p args e mConf =
  case NE.nonEmpty $ unrecognisedOptions p args of
    Just unrecogniseds -> pure $ Left $ NE.map ParseErrorUnrecognised unrecogniseds
    Nothing -> runParserOn p args e mConf

unrecognisedOptions :: Parser a -> Args -> [Opt]
unrecognisedOptions p args =
  let possibleOpts = collectPossibleOpts p
      isRecognised =
        (`S.member` possibleOpts) . \case
          OptArg _ -> PossibleArg
          OptSwitch d -> PossibleSwitch d
          OptOption d _ -> PossibleOption d
   in filter (not . isRecognised) (argMapOpts args)

data PossibleOpt
  = PossibleArg
  | PossibleSwitch !Dashed
  | PossibleOption !Dashed
  deriving (Show, Eq, Ord)

collectPossibleOpts :: Parser a -> Set PossibleOpt
collectPossibleOpts = go
  where
    go :: Parser a -> Set PossibleOpt
    go = \case
      ParserPure _ -> S.empty
      ParserAp p1 p2 -> go p1 `S.union` go p2
      ParserSelect p1 p2 -> go p1 `S.union` go p2
      ParserEmpty -> S.empty
      ParserAlt p1 p2 -> go p1 `S.union` go p2
      ParserMany p -> go p
      ParserCheck _ p -> go p
      -- This isn't right. We need to know which command is in action to know which opts are unrecognised
      -- For that we need context-aware opt parsing
      ParserCommands ne -> S.unions $ map goCommand ne
      ParserWithConfig pc pa -> go pc `S.union` go pa
      ParserSetting _ Setting {..} ->
        S.fromList $
          concat
            [ [PossibleArg | settingTryArgument],
              case settingSwitchValue of
                Nothing -> []
                Just _ -> map PossibleSwitch settingDasheds,
              if settingTryOption
                then map PossibleOption settingDasheds
                else []
            ]
    goCommand :: Command a -> Set PossibleOpt
    goCommand Command {..} = S.insert PossibleArg (go commandParser)

runParserOn ::
  Parser a ->
  Args ->
  EnvMap ->
  Maybe JSON.Object ->
  IO (Either (NonEmpty ParseError) a)
runParserOn p args envVars mConfig =
  validationToEither <$> do
    let ppEnv = PPEnv {ppEnvEnv = envVars, ppEnvConf = mConfig}
    runValidationT $ evalStateT (runReaderT (go p) ppEnv) args
  where
    tryPP :: PP a -> PP (Maybe a)
    tryPP pp = do
      s <- get
      e <- ask
      errOrRes <- liftIO $ runPP pp s e
      case errOrRes of
        -- Note that args are not consumed if the alternative failed.
        Left errs ->
          if all errorIsForgivable errs
            then pure Nothing
            else ppErrors errs
        Right (a, s') -> do
          put s'
          pure $ Just a
    go ::
      Parser a ->
      PP a
    go = \case
      ParserPure a -> pure a
      ParserAp ff fa -> go ff <*> go fa
      ParserEmpty -> ppError ParseErrorEmpty
      ParserSelect fe ff -> select (go fe) (go ff)
      ParserAlt p1 p2 -> do
        eor <- tryPP (go p1)
        case eor of
          Just a -> pure a
          Nothing -> go p2
      ParserMany p' -> do
        eor <- tryPP $ go p'
        case eor of
          Nothing -> pure []
          Just a -> do
            as <- go (ParserMany p')
            pure (a : as)
      ParserCheck f p' -> do
        a <- go p'
        errOrB <- liftIO $ f a
        case errOrB of
          Left err -> ppError $ ParseErrorCheckFailed err
          Right b -> pure b
      ParserCommands cs -> do
        mS <- ppArg
        case mS of
          Nothing -> ppError $ ParseErrorMissingCommand $ map commandArg cs
          Just s -> case find ((== s) . commandArg) cs of
            Nothing -> ppError $ ParseErrorUnrecognisedCommand s (map commandArg cs)
            Just c -> go $ commandParser c
      ParserWithConfig pc pa -> do
        mNewConfig <- go pc
        local (\e -> e {ppEnvConf = mNewConfig}) $ go pa
      ParserSetting _ set@Setting {..} -> do
        mArg <-
          if settingTryArgument
            then do
              -- Require readers before finding the argument so the parser
              -- always fails if it's missing a reader.
              rs <- requireReaders settingReaders
              mS <- ppArg
              case mS of
                Nothing -> pure NotFound
                Just argStr -> do
                  case tryReaders rs argStr of
                    Left errs -> ppError $ ParseErrorArgumentRead errs
                    Right a -> pure $ Found a
            else pure NotRun

        case mArg of
          Found a -> pure a
          _ -> do
            -- TODO do this without all the nesting
            mSwitch <- case settingSwitchValue of
              Nothing -> pure NotRun
              Just a -> do
                mS <- ppSwitch settingDasheds
                case mS of
                  Nothing -> pure NotFound
                  Just () -> pure $ Found a

            case mSwitch of
              Found a -> pure a
              _ -> do
                mOpt <-
                  if settingTryOption
                    then do
                      -- Require readers before finding the option so the parser
                      -- always fails if it's missing a reader.
                      rs <- requireReaders settingReaders
                      mS <- ppOpt settingDasheds
                      case mS of
                        Nothing -> pure NotFound
                        Just optionStr -> do
                          case tryReaders rs optionStr of
                            Left err -> ppError $ ParseErrorOptionRead err
                            Right a -> pure $ Found a
                    else pure NotRun

                case mOpt of
                  Found a -> pure a
                  _ -> do
                    mEnv <- case settingEnvVars of
                      Nothing -> pure NotRun
                      Just ne -> do
                        -- Require readers before finding the env vars so the parser
                        -- always fails if it's missing a reader.
                        rs <- requireReaders settingReaders
                        es <- asks ppEnvEnv
                        let founds = mapMaybe (`EnvMap.lookup` es) (NE.toList ne)
                        -- Run the parser on all specified env vars before
                        -- returning the first because we want to fail if any
                        -- of them fail, even if they wouldn't be the parse
                        -- result.
                        results <- for founds $ \varStr ->
                          case tryReaders rs varStr of
                            Left errs -> ppError $ ParseErrorEnvRead errs
                            Right a -> pure a
                        pure $ maybe NotFound Found $ listToMaybe results

                    case mEnv of
                      Found a -> pure a
                      _ -> do
                        mConf <- case settingConfigVals of
                          Nothing -> pure NotRun
                          Just ((ne, DecodingCodec c) :| _) -> do
                            -- TODO try parsing with the others
                            -- TODO handle subconfig prefix here?
                            mObj <- asks ppEnvConf
                            case mObj of
                              Nothing -> pure NotFound
                              Just obj -> do
                                let jsonParser :: JSON.Object -> NonEmpty String -> JSON.Parser (Maybe JSON.Value)
                                    jsonParser o (k :| rest) = case NE.nonEmpty rest of
                                      Nothing -> o .:? Key.fromString k
                                      Just neRest -> do
                                        mO' <- o .:? Key.fromString k
                                        case mO' of
                                          Nothing -> pure Nothing
                                          Just o' -> jsonParser o' neRest
                                case JSON.parseEither (jsonParser obj) ne of
                                  Left err -> ppError $ ParseErrorConfigRead err
                                  Right mV -> case mV of
                                    Nothing -> pure NotFound
                                    Just v -> case JSON.parseEither (parseJSONVia c) v of
                                      Left err -> ppError $ ParseErrorConfigRead err
                                      Right a -> pure $ Found a

                        case mConf of
                          Found a -> pure a
                          _ ->
                            case settingDefaultValue of
                              Just (a, _) -> pure a
                              Nothing -> do
                                let mOptDoc = settingOptDoc set
                                let mEnvDoc = settingEnvDoc set
                                let mConfDoc = settingConfDoc set
                                let parseResultError e res = case res of
                                      NotRun -> Nothing
                                      NotFound -> Just e
                                      Found _ -> Nothing -- Should not happen.
                                maybe (ppError ParseErrorEmptySetting) ppErrors $
                                  NE.nonEmpty $
                                    catMaybes
                                      [ parseResultError (ParseErrorMissingArgument mOptDoc) mArg,
                                        parseResultError (ParseErrorMissingSwitch mOptDoc) mSwitch,
                                        parseResultError (ParseErrorMissingOption mOptDoc) mOpt,
                                        parseResultError (ParseErrorMissingEnvVar mEnvDoc) mEnv,
                                        parseResultError (ParseErrorMissingConfVal mConfDoc) mConf
                                      ]

data ParseResult a
  = NotRun
  | NotFound
  | Found a

requireReaders :: [Reader a] -> PP (NonEmpty (Reader a))
requireReaders rs = case NE.nonEmpty rs of
  Nothing -> error "no readers configured." -- TODO nicer error
  Just ne -> pure ne

-- Try the readers in order
tryReaders :: NonEmpty (Reader a) -> String -> Either (NonEmpty String) a
tryReaders rs s = left NE.reverse $ go rs
  where
    go (r :| rl) = case runReader r s of
      Left err -> go' (err :| []) rl
      Right a -> Right a
    go' errs = \case
      [] -> Left errs
      (r : rl) -> case runReader r s of
        Left err -> go' (err <| errs) rl
        Right a -> Right a

type PP a = ReaderT PPEnv (StateT PPState (ValidationT ParseError IO)) a

type PPState = Args

data PPEnv = PPEnv
  { ppEnvEnv :: !EnvMap,
    ppEnvConf :: !(Maybe JSON.Object)
  }

runPP ::
  PP a ->
  Args ->
  PPEnv ->
  IO (Either (NonEmpty ParseError) (a, PPState))
runPP p args envVars =
  validationToEither <$> runValidationT (runStateT (runReaderT p envVars) args)

ppArg :: PP (Maybe String)
ppArg = state Args.consumeArgument

ppOpt :: [Dashed] -> PP (Maybe String)
ppOpt ds = state $ Args.consumeOption ds

ppSwitch :: [Dashed] -> PP (Maybe ())
ppSwitch ds = state $ Args.consumeSwitch ds

ppErrors :: NonEmpty ParseError -> PP a
ppErrors = lift . lift . ValidationT . pure . Failure

ppError :: ParseError -> PP a
ppError = ppErrors . NE.singleton
