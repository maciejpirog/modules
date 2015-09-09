{-# LANGUAGE TypeFamilies, MultiParamTypeClasses, FlexibleInstances, DeriveFunctor, GeneralizedNewtypeDeriving, TypeOperators #-}

module Control.Monad.Module.Instances
  (
    -- * Non-empty list
    AtLeast2(..),
    -- * Free monad
    Wrap(..)
  )
  where

import Control.Applicative (Const(..), WrappedMonad(..))
import Control.Monad.Identity (Identity(..))
import Control.Monad.Free (Free(..))
import Control.Monad.State (State(..), runState)
import Control.Monad.Reader (Reader, runReader, ReaderT(..))
import Control.Monad.Writer (Writer, runWriter, WriterT(..))
import Data.Void (Void(..))
import Data.List.NonEmpty (NonEmpty(..))
import Data.Functor.Compose (Compose(..))

import Control.Monad.Module
import Data.Monoid.MonoidIdeal (MonoidIdeal(..))

-- Regular representations

-- | Right regular representation
instance (Monad m) => RModule m (WrappedMonad m) where
  WrapMonad m |>>= k = WrapMonad (m >>= k)

-- | Left regular representation
instance (Monad m) => LModule m (WrappedMonad m) where
  m >>=| k = WrapMonad (m >>= unwrapMonad . k)

-- Composition

instance (Functor f, RModule m r) => RModule m (f `Compose` r) where
  Compose f |>>= k = Compose $ fmap (|>>= k) f

-- Identity

instance RModule Identity (Const Void) where
  Const x |>>= _ = Const x

instance Idealised Identity (Const Void) where
  embed _ = error "constant void..."

instance MonadIdeal Identity where
  type Ideal Identity = Const Void
  split (Identity a)  = Left a

-- Maybe

instance RModule Maybe (Const ()) where
  Const _ |>>= _ = Const ()

instance Idealised Maybe (Const ()) where
  embed _ = Nothing

instance MonadIdeal Maybe where
  type Ideal Maybe = Const ()
  split (Just a)  = Left a
  split (Nothing) = Right $ Const ()

-- Either

instance RModule (Either e) (Const e) where
  Const x |>>= _ = Const x

instance Idealised (Either e) (Const e) where
  embed (Const e) = Left e

instance MonadIdeal (Either e) where
  type Ideal (Either e) = Const e
  split (Left  e) = Right $ Const e
  split (Right a) = Left  a

-- NonEmpty

{- | List with at least two elements -}
data AtLeast2 a = a :|: NonEmpty a
  deriving (Functor)

infixr 4 :|:

fromNonEmpty :: NonEmpty a -> AtLeast2 a
fromNonEmpty (x :| y : xs) = x :|: y :| xs

toNonEmpty :: AtLeast2 a -> NonEmpty a
toNonEmpty (x :|: y :| xs) = x :| y : xs

instance RModule NonEmpty AtLeast2 where
  m |>>= f = fromNonEmpty $ toNonEmpty m >>= f

instance Idealised NonEmpty AtLeast2 where
  embed = toNonEmpty

instance MonadIdeal NonEmpty where
  type Ideal NonEmpty = AtLeast2
  split (x :| []) = Left x
  split xs        = Right $ fromNonEmpty xs

-- Free

{- | Free monad generated by a functor @f@ wrapped in @f@. In other
words, it is the type of \"free monads\" with at least one layer of
@f@.
-}
newtype Wrap f a = Wrap { unWrap :: f (Free f a) }
 deriving (Functor)

instance (Functor f) => RModule (Free f) (Wrap f) where
  (Wrap f) |>>= g = Wrap (fmap (>>= g) f)

instance (Functor f) => Idealised (Free f) (Wrap f) where
  embed = Free . unWrap

instance (Functor f) => MonadIdeal (Free f) where
  type Ideal (Free f) = Wrap f
  split (Pure x) = Left x
  split (Free f) = Right $ Wrap f

-- Reader + Writer

instance RModule (Reader s) (Writer s) where
  w |>>= f = WriterT $ Identity $ (runReader (f a) s, s)
   where (a, s)  = runWriter w

-- State + Writer

instance RModule (State s) (Writer s) where
  w |>>= f = WriterT $ Identity $ runState (f a) s
   where (a, s)  = runWriter w

-- MonoidIdeal

instance (MonoidIdeal r, i ~ MIdeal r) => RModule (Writer r) (Writer i) where
  WriterT (Identity (a, w)) |>>= f =
     case f a of
       WriterT (Identity (b, r)) ->
         WriterT $ Identity (b, w `miappend` r)

instance (MonoidIdeal r, i ~ MIdeal r) => Idealised (Writer r) (Writer i) where
  embed (WriterT (Identity (a, w))) =
     WriterT $ Identity (a, miembed w) 

instance (MonoidIdeal r) => MonadIdeal (Writer r) where
  type Ideal (Writer r) = Writer (MIdeal r)
  split w  = case misplit r of
               Nothing -> Left a
               Just i  -> Right $ WriterT $ Identity (a, i)
   where
    (a, r) = runWriter w
