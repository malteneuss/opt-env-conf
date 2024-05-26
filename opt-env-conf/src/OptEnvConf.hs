{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}

module OptEnvConf
  ( module OptEnvConf,
    module Control.Applicative,
  )
where

import Control.Applicative
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State
import Data.Aeson as JSON
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.Types as JSON
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import Data.Map (Map)
import qualified Data.Map as M
import OptEnvConf.ArgMap (ArgMap (..), Dashed (..))
import qualified OptEnvConf.ArgMap as AM
import OptEnvConf.EnvMap (EnvMap (..))
import qualified OptEnvConf.EnvMap as EM
import System.Environment (getArgs, getEnvironment)
import System.Exit

data Parser a where
  -- Functor
  ParserPure :: a -> Parser a
  -- Applicative
  ParserFmap :: (a -> b) -> Parser a -> Parser b
  ParserAp :: Parser (a -> b) -> Parser a -> Parser b
  -- Alternative
  ParserEmpty :: Parser a
  ParserAlt :: Parser a -> Parser a -> Parser a
  -- | Arguments and options
  ParserArg :: Parser String
  ParserOpt :: String -> Parser (Maybe String)
  -- | Env vars
  ParserEnvVar :: String -> Parser (Maybe String)
  -- | Configuration file
  ParserConfig :: FromJSON a => String -> Parser (Maybe a)

instance Functor Parser where
  fmap = ParserFmap

instance Applicative Parser where
  pure = ParserPure
  (<*>) = ParserAp

instance Alternative Parser where
  empty = ParserEmpty
  (<|>) p1 p2 = case p1 of
    ParserEmpty -> p2
    _ -> case p2 of
      ParserEmpty -> p1
      _ -> ParserAlt p1 p2

class HasParser a where
  optEnvParser :: Parser a

data ArgParser a = ArgParser
  { argParserParse :: !(String -> Either String a),
    argParserShort :: ![Char],
    argParserLong :: ![String]
  }

envVar :: String -> Parser (Maybe String)
envVar = ParserEnvVar

strArg :: Parser String
strArg = ParserArg

strOpt :: String -> Parser (Maybe String)
strOpt = ParserOpt

confVar :: String -> Parser (Maybe String)
confVar = ParserConfig

optionalFirst :: [Parser (Maybe a)] -> Parser (Maybe a)
optionalFirst = undefined

requiredFirst :: [Parser (Maybe a)] -> Parser a
requiredFirst = undefined

documentParser :: Parser a -> String
documentParser = unlines . go
  where
    go :: Parser a -> [String]
    go = \case
      ParserFmap _ p -> go p
      ParserPure _ -> []
      ParserAp pf pa -> go pf ++ go pa
      ParserEmpty -> []
      ParserAlt p1 ParserEmpty -> go p1
      ParserAlt p1 p2 -> go p1 ++ ["or"] ++ go p2
      ParserArg -> ["Argument"]
      ParserOpt v -> ["Option: " <> show v]
      ParserEnvVar v -> ["Env var: " <> show v]
      ParserConfig key -> ["Config var: " <> show key]

showParserABit :: Parser a -> String
showParserABit = ($ "") . go 0
  where
    go :: Int -> Parser a -> ShowS
    go d = \case
      ParserFmap _ p -> showParen (d > 10) $ showString "Fmap _ " . go 11 p
      ParserPure _ -> showParen (d > 10) $ showString "Pure _"
      ParserAp pf pa -> showParen (d > 10) $ showString "Ap " . go 11 pf . go 11 pa
      ParserEmpty -> showString "Empty"
      ParserAlt p1 p2 -> showParen (d > 10) $ showString "Alt " . go 11 p1 . showString " " . go 11 p2
      ParserArg -> showString "Arg"
      ParserOpt v -> showParen (d > 10) $ showString "Opt " . showString v
      ParserEnvVar v -> showParen (d > 10) $ showString "EnvVar " . showsPrec 11 v
      ParserConfig key -> showParen (d > 10) $ showString "Config " . showsPrec 11 key

runParser :: Parser a -> IO a
runParser p = do
  args <- AM.parse <$> getArgs
  envVars <- EM.parse <$> getEnvironment
  let mConf = Nothing

  -- TODO do something with the leftovers
  case runParserPure p args envVars mConf of
    Left err -> die err
    Right (a, _) -> pure a

runParserPure ::
  Parser a ->
  ArgMap ->
  EnvMap ->
  Maybe JSON.Object ->
  Either String (a, [String])
runParserPure p args envVars mConfig =
  runExcept $ do
    (result, unconsumedArgs) <- runStateT (runReaderT (go mConfig p) envVars) args
    when (AM.hasUnconsumed unconsumedArgs) $ throwError "Unconsumed args"
    pure (result, AM.argMapLeftovers unconsumedArgs)
  where
    -- TODO maybe use validation instead of either
    -- TODO typed parseError
    go ::
      Maybe JSON.Object ->
      Parser a ->
      PP a
    go mConf = \case
      ParserFmap f p' -> f <$> go mConf p'
      ParserPure a -> pure a
      ParserAp ff fa -> go mConf ff <*> go mConf fa
      ParserEmpty -> throwError "ParserEmpty"
      ParserAlt p1 p2 -> do
        as <- get
        es <- ask
        case runPP (go mConf p1) as es of
          Right (a, as') -> do
            put as'
            pure a
          -- Note that args are not consumed if the alternative failed.
          Left _ -> go mConf p2 -- TODO: Maybe collect the error?
      ParserArg -> do
        mA <- ppArg
        case mA of
          Nothing -> throwError "No argument to consume"
          Just a -> pure a
      ParserOpt _ -> undefined
      ParserEnvVar v -> do
        es <- ask
        pure (EM.lookup v es)
      ParserConfig key -> case mConf of
        Nothing -> pure Nothing
        Just conf -> case JSON.parseEither (.: Key.fromString key) conf of
          Left err -> throwError err
          Right v -> pure (Just v)

type PP a = ReaderT EnvMap (StateT ArgMap (Except String)) a

runPP ::
  PP a ->
  ArgMap ->
  EnvMap ->
  Either String (a, ArgMap)
runPP p args envVars =
  runExcept $ runStateT (runReaderT p envVars) args

ppArg :: PP (Maybe String)
ppArg = state AM.consumeArg
