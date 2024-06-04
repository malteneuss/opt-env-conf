{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}

module OptEnvConf.Run where

import Autodocodec
import Autodocodec.Yaml
import Control.Applicative
import Control.Monad
import Control.Monad.Reader
import Control.Monad.State
import Data.Aeson ((.:))
import qualified Data.Aeson as JSON
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.Types as JSON
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import Data.Set (Set)
import qualified Data.Set as S
import OptEnvConf.ArgMap (ArgMap (..), Dashed (..), Opt (..))
import qualified OptEnvConf.ArgMap as ArgMap
import OptEnvConf.Doc
import OptEnvConf.EnvMap (EnvMap (..))
import qualified OptEnvConf.EnvMap as EnvMap
import OptEnvConf.Error
import OptEnvConf.Opt
import OptEnvConf.Parser
import OptEnvConf.Reader
import OptEnvConf.Validation
import Path
import Path.IO
import System.Environment (getArgs, getEnvironment)
import System.Exit
import System.IO
import Text.Colour
import Text.Colour.Capabilities.FromEnv

runParser :: Parser a -> IO a
runParser = fmap fst . runParserWithLeftovers

runParserWithLeftovers :: Parser a -> IO (a, [String])
runParserWithLeftovers p = do
  args <- getArgs
  let (argMap, leftovers) = ArgMap.parse args
  envVars <- EnvMap.parse <$> getEnvironment

  errOrConfResult <- runParserComplete defaultConfigFileParser argMap envVars Nothing

  tc <- getTerminalCapabilitiesFromHandle stderr

  -- TODO try using selective for the parser so we only need to run the parser
  -- once and all the docs happen automatically?
  case errOrConfResult of
    Left errs -> do
      hPutChunksLocaleWith tc stderr $ renderErrors errs
      exitFailure
    Right mConfigFile -> do
      mConf <- fmap join $ mapM readYamlConfigFile mConfigFile

      errOrResult <- runParserComplete p argMap envVars mConf
      case errOrResult of
        Left errs -> do
          hPutChunksLocaleWith tc stderr $ renderErrors errs
          exitFailure
        Right a -> pure (a, leftovers)

defaultConfigFileParser :: Parser (Maybe (Path Abs File))
defaultConfigFileParser =
  mapIO (mapM resolveFile') $
    optionalFirst
      [ optional $
          strOption
            [ long "config-file",
              help "Configuration file path"
            ],
        optional $
          envVar
            str
            [ var "CONFIG_FILE",
              help "Configuration file path"
            ]
      ]

-- 'runParserOn' _and_ 'unrecognisedOptions'
runParserComplete ::
  Parser a ->
  ArgMap ->
  EnvMap ->
  Maybe JSON.Object ->
  IO (Either (NonEmpty ParseError) a)
runParserComplete p args env mConf =
  case NE.nonEmpty $ unrecognisedOptions p args of
    Just unrecogniseds -> pure $ Left $ NE.map ParseErrorUnrecognised unrecogniseds
    Nothing -> runParserOn p args env mConf

unrecognisedOptions :: Parser a -> ArgMap -> [Opt]
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
      ParserFmap _ p -> go p
      ParserAp p1 p2 -> go p1 `S.union` go p2
      ParserEmpty -> S.empty
      ParserAlt p1 p2 -> go p1 `S.union` go p2
      ParserMany p -> go p
      ParserSome p -> go p
      ParserMapIO _ p -> go p
      ParserWithConfig pc pa -> go pc `S.union` go pa
      ParserOptionalFirst p -> S.unions $ map go p
      ParserRequiredFirst p -> S.unions $ map go p
      ParserArg _ _ -> S.singleton PossibleArg
      ParserOpt _ o -> S.fromList $ map PossibleOption $ optionSpecificsDasheds $ optionGeneralSpecifics o
      ParserEnvVar _ _ -> S.empty
      ParserConfig _ _ -> S.empty

runParserOn ::
  Parser a ->
  ArgMap ->
  EnvMap ->
  Maybe JSON.Object ->
  IO (Either (NonEmpty ParseError) a)
runParserOn p args envVars mConfig =
  validationToEither <$> do
    let ppEnv = PPEnv {ppEnvEnv = envVars, ppEnvConf = mConfig}
    runValidationT $ evalStateT (runReaderT (go p) ppEnv) args
  where
    tryPP :: PP a -> PP (Either (NonEmpty ParseError) (a, PPState))
    tryPP pp = do
      s <- get
      e <- ask
      liftIO $ runPP pp s e
    go ::
      Parser a ->
      PP a
    go = \case
      ParserFmap f p' -> f <$> go p'
      ParserPure a -> pure a
      ParserAp ff fa -> go ff <*> go fa
      ParserEmpty -> ppError ParseErrorEmpty
      ParserAlt p1 p2 -> do
        eor <- tryPP (go p1)
        case eor of
          Right (a, s') -> do
            put s'
            pure a
          -- Note that args are not consumed if the alternative failed.
          Left _ -> go p2 -- TODO: Maybe collect the error?
      ParserMany p' -> do
        eor <- tryPP $ go p'
        case eor of
          Left _ -> pure [] -- Err if fails, the end
          Right (a, s') -> do
            put s'
            as <- go (ParserMany p')
            pure (a : as)
      ParserSome p' -> do
        a <- go p'
        as <- go $ ParserMany p'
        pure $ a :| as
      ParserMapIO f p' -> do
        a <- go p'
        liftIO $ f a
      ParserWithConfig pc pa -> do
        mNewConfig <- go pc
        local (\e -> e {ppEnvConf = mNewConfig}) $ go pa
      ParserOptionalFirst pss -> case pss of
        [] -> pure Nothing
        (p' : ps) -> do
          eor <- tryPP $ go p'
          case eor of
            Left err -> ppErrors err -- Error if any fails, don't ignore it.
            Right (mA, s') -> case mA of
              Nothing -> go $ ParserOptionalFirst ps -- Don't record the state and continue to try to parse the next
              Just a -> do
                put s' -- Record the state
                pure (Just a)
      ParserRequiredFirst pss -> case pss of
        [] -> ppError ParseErrorRequired
        (p' : ps) -> do
          eor <- tryPP $ go p'
          case eor of
            Left err -> ppErrors err -- Error if any fails, don't ignore it.
            Right (mA, s') -> case mA of
              Nothing -> go $ ParserRequiredFirst ps -- Don't record the state and continue to try to parse the next
              Just a -> do
                put s' -- Record the state of the parser that succeeded
                pure a
      ParserArg r o -> do
        mS <- ppArg
        case mS of
          Nothing -> ppError $ ParseErrorMissingArgument $ argumentOptDoc o
          Just s -> case r s of
            Left err -> ppError $ ParseErrorArgumentRead err
            Right a -> pure a
      ParserOpt r o -> do
        let ds = optionSpecificsDasheds $ optionGeneralSpecifics o
        mS <- ppOpt ds
        case mS of
          Nothing -> ppError $ ParseErrorMissingOption $ optionOptDoc o
          Just s -> do
            case r s of
              Left err -> ppError $ ParseErrorOptionRead err
              Right a -> pure a
      ParserEnvVar r o -> do
        es <- asks ppEnvEnv
        case msum $ map (`EnvMap.lookup` es) (envSpecificsVars (optionGeneralSpecifics o)) of
          Nothing -> ppError $ ParseErrorMissingEnvVar $ envEnvDoc o
          Just s ->
            case r s of
              Left err -> ppError $ ParseErrorEnvRead err
              Right a -> pure a
      ParserConfig key c -> do
        mConf <- asks ppEnvConf
        case mConf of
          Nothing -> ppError $ ParseErrorMissingConfig key
          Just conf -> case JSON.parseEither (.: Key.fromString key) conf of
            Left err -> ppError $ ParseErrorConfigRead err
            Right v -> case JSON.parseEither (parseJSONVia c) v of
              Left err -> ppError $ ParseErrorConfigRead err
              Right a -> pure a

type PP a = ReaderT PPEnv (StateT PPState (ValidationT ParseError IO)) a

type PPState = ArgMap

data PPEnv = PPEnv
  { ppEnvEnv :: !EnvMap,
    ppEnvConf :: !(Maybe JSON.Object)
  }

runPP ::
  PP a ->
  ArgMap ->
  PPEnv ->
  IO (Either (NonEmpty ParseError) (a, PPState))
runPP p args envVars =
  validationToEither <$> runValidationT (runStateT (runReaderT p envVars) args)

ppArg :: PP (Maybe String)
ppArg = state ArgMap.consumeArgument

ppOpt :: [Dashed] -> PP (Maybe String)
ppOpt ds = state $ ArgMap.consumeOption ds

ppErrors :: NonEmpty ParseError -> PP a
ppErrors = lift . lift . ValidationT . pure . Failure

ppError :: ParseError -> PP a
ppError = ppErrors . NE.singleton
