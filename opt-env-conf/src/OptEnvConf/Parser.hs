{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module OptEnvConf.Parser
  ( -- * Parser API
    setting,
    subArgs,
    subEnv,
    subConfig,
    subSettings,
    someNonEmpty,
    mapIO,
    withConfig,
    withYamlConfig,
    xdgYamlConfigFile,
    withLocalYamlConfig,
    enableDisableSwitch,
    choice,

    -- * Parser implementation
    Parser (..),
    HasParser (..),
    Metavar,
    Help,
    showParserABit,

    -- ** Re-exports
    Functor (..),
    Applicative (..),
    Alternative (..),
    Selective (..),
  )
where

import Autodocodec.Yaml
import Control.Applicative
import Control.Arrow (first)
import Control.Monad
import Control.Selective
import Data.Aeson as JSON
import qualified Data.Char as Char
import Data.List.NonEmpty (NonEmpty (..), (<|))
import qualified Data.List.NonEmpty as NE
import Data.Maybe
import OptEnvConf.ArgMap (Dashed (..), prefixDashed)
import OptEnvConf.Reader
import OptEnvConf.Setting
import Path.IO
import System.FilePath

data Parser a where
  -- Functor
  ParserPure :: !a -> Parser a
  -- Applicative
  ParserFmap :: !(a -> b) -> !(Parser a) -> Parser b
  ParserAp :: !(Parser (a -> b)) -> !(Parser a) -> Parser b
  -- Selective
  ParserSelect :: !(Parser (Either a b)) -> !(Parser (a -> b)) -> Parser b
  -- Alternative
  ParserEmpty :: Parser a
  ParserAlt :: !(Parser a) -> !(Parser a) -> Parser a
  ParserMany :: !(Parser a) -> Parser [a]
  -- | Apply a computation to the result of a parser
  --
  -- This is intended for use-cases like resolving a file to an absolute path.
  -- It is morally ok for read-only IO actions but you will
  -- have a bad time if the action is not read-only.
  ParserMapIO :: !(a -> IO b) -> !(Parser a) -> Parser b
  -- | Load a configuration value and use it for the continuing parser
  ParserWithConfig :: Parser (Maybe JSON.Object) -> !(Parser a) -> Parser a
  -- | General settings
  ParserSetting :: !(Setting a) -> Parser a

instance Functor Parser where
  fmap f = \case
    ParserFmap g p -> ParserFmap (f . g) p
    ParserMapIO g p -> ParserMapIO (fmap f . g) p
    p -> ParserFmap f p

instance Applicative Parser where
  pure = ParserPure
  (<*>) = ParserAp

instance Selective Parser where
  select = ParserSelect

instance Alternative Parser where
  empty = ParserEmpty
  (<|>) p1 p2 =
    let isEmpty :: Parser a -> Bool
        isEmpty = \case
          ParserFmap _ p' -> isEmpty p'
          ParserPure _ -> False
          ParserAp pf pa -> isEmpty pf && isEmpty pa
          ParserSelect pe pf -> isEmpty pe && isEmpty pf
          ParserEmpty -> True
          ParserAlt _ _ -> False
          ParserMany _ -> False
          ParserMapIO _ p' -> isEmpty p'
          ParserWithConfig pc ps -> isEmpty pc && isEmpty ps
          ParserSetting _ -> False
     in case (isEmpty p1, isEmpty p2) of
          (True, True) -> ParserEmpty
          (True, False) -> p2
          (False, True) -> p1
          (False, False) -> ParserAlt p1 p2
  many = ParserMany

  some p = (:) <$> p <*> many p

showParserABit :: Parser a -> String
showParserABit = ($ "") . go 0
  where
    go :: Int -> Parser a -> ShowS
    go d = \case
      ParserFmap _ p ->
        showParen (d > 10) $
          showString "Fmap _ "
            . go 11 p
      ParserPure _ -> showParen (d > 10) $ showString "Pure _"
      ParserAp pf pa ->
        showParen (d > 10) $
          showString "Ap "
            . go 11 pf
            . showString " "
            . go 11 pa
      ParserSelect pe pf ->
        showParen (d > 10) $
          showString "Select "
            . go 11 pe
            . showString " "
            . go 11 pf
      ParserEmpty -> showString "Empty"
      ParserAlt p1 p2 ->
        showParen (d > 10) $
          showString "Alt "
            . go 11 p1
            . showString " "
            . go 11 p2
      ParserMany p ->
        showParen (d > 10) $
          showString "Many "
            . go 11 p
      ParserMapIO _ p ->
        showParen (d > 10) $
          showString "MapIO _ "
            . go 11 p
      ParserWithConfig p1 p2 ->
        showParen (d > 10) $
          showString "WithConfig _ "
            . go 11 p1
            . showString " "
            . go 11 p2
      ParserSetting p ->
        showParen (d > 10) $
          showString "Setting "
            . showSettingABit p

class HasParser a where
  settingsParser :: Parser a

setting :: [Builder a] -> Parser a
setting = ParserSetting . buildSetting

buildSetting :: [Builder a] -> Setting a
buildSetting = completeBuilder . mconcat

someNonEmpty :: Parser a -> Parser (NonEmpty a)
someNonEmpty p = (:|) <$> p <*> many p

mapIO :: (a -> IO b) -> Parser a -> Parser b
mapIO = ParserMapIO

withConfig :: Parser (Maybe JSON.Object) -> Parser a -> Parser a
withConfig = ParserWithConfig

withYamlConfig :: Parser (Maybe FilePath) -> Parser a -> Parser a
withYamlConfig pathParser = withConfig $ mapIO (fmap join . mapM (resolveFile' >=> readYamlConfigFile)) pathParser

xdgYamlConfigFile :: FilePath -> Parser FilePath
xdgYamlConfigFile subdir =
  (\xdgDir -> xdgDir </> subdir </> "config.yaml")
    <$> setting
      [ reader str,
        env "XDG_CONFIG_HOME",
        metavar "DIRECTORY",
        help "Path to the XDG configuration directory"
      ]

withLocalYamlConfig :: Parser a -> Parser a
withLocalYamlConfig =
  withYamlConfig $
    Just
      <$> setting
        [ reader str,
          option,
          long "config-file",
          env "CONFIG_FILE",
          metavar "FILE",
          value "config.yaml",
          help "Path to the configuration file"
        ]

enableDisableSwitch :: Bool -> [Builder Bool] -> Parser Bool
enableDisableSwitch defaultBool builders =
  choice $
    catMaybes
      [ Just parseDummy,
        Just parseDisableSwitch,
        Just parseEnableSwitch,
        parseEnableEnv,
        parseDisableEnv,
        parseConfigVal,
        Just $ pure defaultBool
      ]
  where
    s = buildSetting builders
    parseEnableSwitch :: Parser Bool
    parseEnableSwitch =
      ParserSetting $
        Setting
          { settingDasheds = mapMaybe (prefixDashedLong "enable-") (settingDasheds s),
            settingReaders = [],
            settingTryArgument = False,
            settingSwitchValue = Just True,
            settingTryOption = False,
            settingEnvVars = Nothing,
            settingConfigVals = Nothing,
            settingDefaultValue = Nothing,
            settingHidden = True,
            settingMetavar = Nothing,
            settingHelp = Nothing
          }
    parseDisableSwitch :: Parser Bool
    parseDisableSwitch =
      ParserSetting $
        Setting
          { settingDasheds = mapMaybe (prefixDashedLong "disable-") (settingDasheds s),
            settingReaders = [],
            settingTryArgument = False,
            settingSwitchValue = Just False,
            settingTryOption = False,
            settingEnvVars = Nothing,
            settingConfigVals = Nothing,
            settingDefaultValue = Nothing,
            settingHidden = True,
            settingMetavar = Nothing,
            settingHelp = Nothing
          }

    prefixOrReplaceEnv :: String -> String -> String
    prefixOrReplaceEnv prefix = \case
      "" -> prefix
      v -> prefix <> "_" <> v

    parseEnableEnv :: Maybe (Parser Bool)
    parseEnableEnv = do
      guard (not defaultBool)
      pure $
        ParserSetting $
          Setting
            { settingDasheds = [],
              settingReaders = (exists :) $ settingReaders s,
              settingTryArgument = False,
              settingSwitchValue = Nothing,
              settingTryOption = False,
              settingEnvVars =
                if defaultBool
                  then Nothing
                  else fmap (NE.map (prefixOrReplaceEnv "ENABLE" . map Char.toUpper)) (settingEnvVars s),
              settingConfigVals = Nothing,
              settingDefaultValue = Nothing,
              settingHidden = False,
              settingMetavar = Just "ANY",
              settingHelp = settingHelp s
            }
    parseDisableEnv :: Maybe (Parser Bool)
    parseDisableEnv = do
      guard defaultBool
      pure $
        ParserSetting $
          Setting
            { settingDasheds = [],
              settingReaders = ((fmap not . exists) :) $ settingReaders s,
              settingTryArgument = False,
              settingSwitchValue = Nothing,
              settingTryOption = False,
              settingEnvVars =
                if defaultBool
                  then fmap (NE.map (prefixOrReplaceEnv "DISABLE" . map Char.toUpper)) (settingEnvVars s)
                  else Nothing,
              settingConfigVals = Nothing,
              settingDefaultValue = Nothing,
              settingHidden = False,
              settingMetavar = Just "ANY",
              settingHelp = settingHelp s
            }
    parseConfigVal :: Maybe (Parser Bool)
    parseConfigVal = do
      ne <- settingConfigVals s
      pure $
        ParserSetting $
          Setting
            { settingDasheds = [],
              settingReaders = [],
              settingTryArgument = False,
              settingSwitchValue = Nothing,
              settingTryOption = False,
              settingEnvVars = Nothing,
              settingConfigVals = Just ne,
              settingDefaultValue = Nothing,
              settingHidden = False,
              settingMetavar = Nothing,
              settingHelp = settingHelp s
            }
    parseDummy :: Parser Bool
    parseDummy =
      ParserSetting $
        Setting
          { settingDasheds = mapMaybe (prefixDashedLong "(enable|disable)-") (settingDasheds s),
            settingReaders = [],
            settingTryArgument = False,
            settingSwitchValue = Just True, -- Unused
            settingTryOption = False,
            settingEnvVars = Nothing,
            settingConfigVals = Nothing,
            settingDefaultValue = Nothing,
            settingHidden = False,
            settingMetavar = Just $ fromMaybe "ANY" $ settingMetavar s,
            settingHelp = settingHelp s
          }
    prefixDashedLong :: String -> Dashed -> Maybe Dashed
    prefixDashedLong prefix = \case
      DashedShort _ -> Nothing
      d -> Just $ prefixDashed prefix d

choice :: [Parser a] -> Parser a
choice = \case
  [] -> ParserEmpty
  [c] -> c
  (c : cs) -> c <|> choice cs

{-# ANN subArgs ("NOCOVER" :: String) #-}
subArgs :: String -> Parser a -> Parser a
subArgs prefix = parserMapSetting $ \s ->
  s {settingDasheds = map (prefixDashed prefix) (settingDasheds s)}

{-# ANN subEnv ("NOCOVER" :: String) #-}
subEnv :: String -> Parser a -> Parser a
subEnv prefix = parserMapSetting $ \s ->
  s {settingEnvVars = NE.map (prefix <>) <$> settingEnvVars s}

{-# ANN subConfig ("NOCOVER" :: String) #-}
subConfig :: String -> Parser a -> Parser a
subConfig prefix = parserMapSetting $ \s ->
  s {settingConfigVals = NE.map (first (prefix <|)) <$> settingConfigVals s}

subSettings :: (HasParser a) => String -> Parser a
subSettings prefix =
  subArgs (map Char.toLower prefix <> "-") $
    subEnv (map Char.toUpper prefix <> "_") $
      subConfig
        prefix
        settingsParser

parserMapSetting :: (forall a. Setting a -> Setting a) -> Parser s -> Parser s
parserMapSetting func = go
  where
    go :: Parser s -> Parser s
    go = \case
      ParserPure a -> ParserPure a
      ParserFmap f p -> ParserFmap f (go p)
      ParserAp p1 p2 -> ParserAp (go p1) (go p2)
      ParserSelect p1 p2 -> ParserSelect (go p1) (go p2)
      ParserEmpty -> ParserEmpty
      ParserAlt p1 p2 -> ParserAlt p1 p2
      ParserMany p -> ParserMany (go p)
      ParserMapIO f p -> ParserMapIO f (go p)
      ParserWithConfig p1 p2 -> ParserWithConfig p1 p2
      ParserSetting s -> ParserSetting $ func s
