{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}

module OptEnvConf.Validation where

import Control.Monad.IO.Class
import Control.Monad.Trans
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import Data.Validity (Validity (..))
import GHC.Generics

-- TODO define Validation in terms of ValidationT so we can use polymorphic functions?
newtype ValidationT e m a = ValidationT {unValidationT :: m (Validation e a)}
  deriving (Functor)

instance (Applicative m) => Applicative (ValidationT e m) where
  pure = ValidationT . pure . Success
  (ValidationT m1) <*> (ValidationT m2) =
    ValidationT $
      (<*>) <$> m1 <*> m2

instance (Monad m) => Monad (ValidationT e m) where
  (ValidationT m) >>= f = ValidationT $ do
    va <- m
    case va of
      Failure es -> pure $ Failure es
      Success a -> unValidationT $ f a

instance MonadTrans (ValidationT e) where
  lift f = ValidationT $ Success <$> f

instance (MonadIO m) => MonadIO (ValidationT e m) where
  liftIO io = ValidationT $ Success <$> liftIO io

runValidationT :: ValidationT e m a -> m (Validation e a)
runValidationT = unValidationT

liftValidation :: (Applicative m) => Validation e a -> ValidationT e m a
liftValidation v = ValidationT $ pure v

validationTFailure :: (Applicative m) => e -> ValidationT e m a
validationTFailure = ValidationT . pure . validationFailure

transformValidationT :: (m (Validation e a) -> n (Validation f b)) -> ValidationT e m a -> ValidationT f n b
transformValidationT func (ValidationT t) = ValidationT $ func t

data Validation e a
  = Failure !(NonEmpty e)
  | Success !a
  deriving (Generic, Show)

instance (Validity e, Validity a) => Validity (Validation e a)

instance Functor (Validation e) where
  fmap _ (Failure e) = Failure e
  fmap f (Success a) = Success (f a)

instance Applicative (Validation e) where
  pure = Success
  Failure e1 <*> b = Failure $ case b of
    Failure e2 -> e1 `NE.append` e2
    Success _ -> e1
  Success _ <*> Failure e2 = Failure e2
  Success f <*> Success a = Success (f a)

instance Monad (Validation e) where
  return = pure
  Success a >>= f = f a
  Failure es >>= _ = Failure es

validationFailure :: e -> Validation e a
validationFailure e = Failure (e :| [])

mapValidationFailure :: (e1 -> e2) -> Validation e1 a -> Validation e2 a
mapValidationFailure f = \case
  Success a -> Success a
  Failure errs -> Failure $ NE.map f errs

validationToEither :: Validation e a -> Either (NonEmpty e) a
validationToEither = \case
  Success a -> Right a
  Failure ne -> Left ne