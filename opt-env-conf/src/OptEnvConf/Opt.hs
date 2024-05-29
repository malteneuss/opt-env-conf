{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RecordWildCards #-}

module OptEnvConf.Opt where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NE
import OptEnvConf.ArgMap (Dashed (..))

type Metavar = String

type Help = String

data OptionGenerals f = OptionGenerals
  -- TODO Completer
  { optionGeneralSpecifics :: f,
    optionGeneralHelp :: !(Maybe String)
  }

emptyOptionGeneralsWith :: f -> OptionGenerals f
emptyOptionGeneralsWith f =
  OptionGenerals
    { optionGeneralSpecifics = f,
      optionGeneralHelp = Nothing
    }

showOptionGeneralsABitWith :: (f -> ShowS) -> OptionGenerals f -> ShowS
showOptionGeneralsABitWith func OptionGenerals {..} =
  showParen True $
    showString "OptionGenerals "
      . func optionGeneralSpecifics
      . showString " "
      . showParen
        True
        ( showString "OptionGenerals "
            . showsPrec 11 optionGeneralHelp
        )

newtype Builder f = Builder {unBuilder :: OptionGenerals f -> OptionGenerals f}

class CanComplete f where
  completeBuilder :: Builder f -> OptionGenerals f

instance Semigroup (Builder f) where
  (<>) (Builder f1) (Builder f2) = Builder (f2 . f1)

instance Monoid (Builder f) where
  mempty = Builder id
  mappend = (<>)

class HasLong a where
  addLong :: NonEmpty Char -> a -> a

instance HasLong f => HasLong (OptionGenerals f) where
  addLong s op = op {optionGeneralSpecifics = addLong s (optionGeneralSpecifics op)}

class HasShort a where
  addShort :: Char -> a -> a

instance HasShort f => HasShort (OptionGenerals f) where
  addShort c op = op {optionGeneralSpecifics = addShort c (optionGeneralSpecifics op)}

class HasMetavar a where
  setMetavar :: Metavar -> a -> a

-- data SwitchSpecifics = SwitchSpecifics
--
-- type SwitchParser = OptionGenerals SwitchSpecifics
--
-- type SwitchBuilder a = SwitchParser a -> SwitchParser a

data OptionSpecifics a = OptionSpecifics
  -- TODO completer
  { optionSpecificsDasheds :: ![Dashed],
    optionSpecificsMetavar :: !(Maybe Metavar)
  }

instance HasLong (OptionSpecifics a) where
  addLong s os = os {optionSpecificsDasheds = DashedLong s : optionSpecificsDasheds os}

instance HasShort (OptionSpecifics a) where
  addShort c os = os {optionSpecificsDasheds = DashedShort c : optionSpecificsDasheds os}

instance HasMetavar (OptionSpecifics a) where
  setMetavar mv os = os {optionSpecificsMetavar = Just mv}

instance CanComplete (OptionSpecifics a) where
  completeBuilder b = unBuilder b emptyOptionParser

type OptionParser a = OptionGenerals (OptionSpecifics a)

emptyOptionParser :: OptionParser a
emptyOptionParser =
  emptyOptionGeneralsWith
    OptionSpecifics
      { optionSpecificsDasheds = [],
        optionSpecificsMetavar = Nothing
      }

showOptionParserABit :: OptionParser a -> ShowS
showOptionParserABit = showOptionGeneralsABitWith $ \OptionSpecifics {..} ->
  showString "OptionSpecifics "
    . showsPrec 11 optionSpecificsDasheds
    . showString " "
    . showsPrec 11 optionSpecificsMetavar

type OptionBuilder a = Builder (OptionSpecifics a)

data ArgumentSpecifics a = ArgumentSpecifics
  -- TODO Completer
  { argumentSpecificsMetavar :: !(Maybe Metavar)
  }

instance CanComplete (ArgumentSpecifics a) where
  completeBuilder b = unBuilder b emptyArgumentParser

instance HasMetavar (ArgumentSpecifics a) where
  setMetavar mv os = os {argumentSpecificsMetavar = Just mv}

type ArgumentParser a = OptionGenerals (ArgumentSpecifics a)

emptyArgumentParser :: ArgumentParser a
emptyArgumentParser =
  emptyOptionGeneralsWith
    ArgumentSpecifics
      { argumentSpecificsMetavar = Nothing
      }

showArgumentParserABit :: ArgumentParser a -> ShowS
showArgumentParserABit = showOptionGeneralsABitWith $ \ArgumentSpecifics {..} ->
  showString "ArgumentSpecifics "
    . showsPrec 11 argumentSpecificsMetavar

type ArgumentBuilder a = Builder (ArgumentSpecifics a)

help :: String -> Builder f
help s = Builder $ \op -> op {optionGeneralHelp = Just s}

metavar :: HasMetavar f => String -> Builder f
metavar s = Builder $ \op -> op {optionGeneralSpecifics = setMetavar s (optionGeneralSpecifics op)}

long :: HasLong f => String -> Builder f
long "" = error "Cannot use an empty long-form option."
long s = Builder $ \op -> op {optionGeneralSpecifics = addLong (NE.fromList s) (optionGeneralSpecifics op)}

short :: HasShort f => Char -> Builder f
short c = Builder $ \op -> op {optionGeneralSpecifics = addShort c (optionGeneralSpecifics op)}
