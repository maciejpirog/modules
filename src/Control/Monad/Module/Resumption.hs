{-# LANGUAGE TypeFamilies,
             MultiParamTypeClasses,
             FlexibleInstances,
             RankNTypes,
             DeriveFunctor,
             ScopedTypeVariables,
             GeneralizedNewtypeDeriving
 #-}

{-|
Module      : Control.Monad.Module.Resumption
Copyright   : (c) 2015 Maciej Piróg
License     : MIT
Maintainer  : maciej.adam.pirog@gmail.com
Stability   : experimental

Generalised resumption monad a la M. Piróg, N. Wu, J. Gibbons
/Modules over monads and their algebras/
<https://coalg.org/calco15/papers/p18-Piróg.pdf>.

The @'Resumption'@ datatype has a couple of interesting
instances for different modules. For example:

* "Control.Monad.State.AllStates" - State-like transformer that accumulates all the intermediate states

* "Control.Monad.State.SnapStates" - State-like transformer that accumulates the selected intermediate states

* 'MoggiResumption' - also known as the free monad transformer
-}
module Control.Monad.Module.Resumption
  (
    -- * Datatype of generalised resumptions
    Resumption(..),
    MNonPure(..),
    liftMonad,
    liftModule,
    hoistResumption,
    distr,
    -- ** Folding resumptions
    foldResumption,
    interpResumption,
    foldFirstLayer,
    foldFirstLayerM,
    -- ** Unfolding resumptions
    unfoldResumption,
    splitHead,    
    -- * Moggi's resumption monad transformers
    -- $moggiR
    FM(..),
    MoggiResumption(..),
    force,
    hold,
    toFM,
    hoistMoggiR,
    -- ** Folding Moggi's transformers
    foldFM,
    foldMoggiR,
    interpFM,
    interpMoggiR,
    -- ** Unfolding Moggi's transformers
    unfoldMoggiR,
    -- ** Right regular representation resumptions
    RRRResumption(..),
    retractRRRR
  )
  where

import Control.Applicative (Applicative(..), WrappedMonad(..))
import Control.Monad (ap, liftM)
import Control.Monad.Free (Free(..), iter, foldFree, liftF,
                            hoistFree)
import Control.Monad.Trans (MonadTrans(..))
import Control.Monad.Identity (Identity(..))
import Data.Functor.Apply (Apply(..))
import Data.Functor.Bind (Bind(..))
import Data.Foldable (Foldable(..))
import Data.Traversable (Traversable(..))

import Control.Monad.Module
import Control.Monad.Free.NonPure hiding (unfoldNonPure)

--
-- RESUMPTION
--

-- | The generalised resumption monad is a composition of a monad
-- @m@ and the free monad generated by @r@ (intended to be a right
-- module over @m@).
newtype Resumption m r a =
  Resumption { unResumption :: m (Free r a) }

instance (Monad m, Functor r) => Functor (Resumption m r) where
  fmap h (Resumption m) = Resumption $ liftM (fmap h) m

ext :: (RModule m r) => (a -> Resumption m r b) -> Free r a ->
  m (Free r b)
ext f (Pure a) = unResumption $ f a
ext f (Free r) = return $ Free $ r |>>= ext f

instance (RModule m r) => Monad (Resumption m r) where
  return = Resumption . return . return
  Resumption m >>= f = Resumption $ m >>= ext f

instance (RModule m r) => Applicative (Resumption m r) where
  pure = return
  (<*>) = ap

instance (RModule m r) => Apply (Resumption m r) where
  (<.>) = (<*>)

instance (RModule m r) => Bind (Resumption m r) where
  (>>-) = (>>=)

instance (Foldable m, Foldable r, RModule m r) =>
  Foldable (Resumption m r)
 where
  foldMap f (Resumption m) = foldMap id $ liftM (foldMap f) m

instance (RModule m r, Traversable m, Traversable r) =>
  Traversable (Resumption m r)
 where
  traverse f (Resumption m) =
    fmap Resumption $ sequenceA $ liftM (traverse f) m

--
-- MNONPURE
--

-- | Type of resumptions with at least one level of free structure.
newtype MNonPure m r a = MNonPure { unMNonPure :: m (NonPure r a) }

instance (Monad m, Functor r) => Functor (MNonPure m r) where
  fmap h (MNonPure m) = MNonPure $ liftM (fmap h) m

instance (RModule m r) =>
  RModule (Resumption m r) (MNonPure m r)
 where
  MNonPure m |>>= f = MNonPure $ 
    liftM (\(NonPure r) -> NonPure $ r |>>= ext f) m

instance (RModule m r) =>
  Idealised (Resumption m r) (MNonPure m r)
 where
  embed (MNonPure m) = Resumption $ liftM (Free . unNonPure) m

instance (RModule m r) => Apply (MNonPure m r) where
  m <.> np = m |>>= (\f ->
    (embed :: MNonPure m r a -> Resumption m r a) np
      >>= (return . f))

instance (RModule m r) => Bind (MNonPure m r) where
  np >>- f = np |>>=
    ((embed :: MNonPure m r a -> Resumption m r a) . f)

instance (Foldable m, Foldable r, RModule m r) =>
  Foldable (MNonPure m r)
 where
  foldMap f (MNonPure m) = foldMap id $ liftM (foldMap f) m

instance (RModule m r, Traversable m, Traversable r) =>
  Traversable (MNonPure m r)
 where
  traverse f (MNonPure m) = fmap MNonPure $ traverse (traverse f) m

--
-- FUNCTIONS
--

-- | Lifts a computation in a monad @m@ to a computation in the
-- resumption monad.
liftMonad :: (RModule m r) => m a -> Resumption m r a
liftMonad = Resumption . liftM Pure

-- | Lifts a value of a right module over a monad @m@ to a
-- computation in the resumption monad.
liftModule :: (RModule m r) => r a -> Resumption m r a
liftModule = Resumption . return . Free . fmap Pure

-- | Run a monad morphism and a natural transformation (a module
-- morphism) through the structure.
hoistResumption :: (RModule m r, RModule n s) =>
  (forall x. m x -> n x) -> (forall x. r x -> s x) ->
  Resumption m r a -> Resumption n s a
hoistResumption h g (Resumption m) =
  Resumption $ h $ liftM (hoistFree g) m

-- | Distributive law of the free monad generated by a module
-- over a monad.
distr :: (RModule m r) => Free r (m a) -> m (Free r a)
distr = ext liftMonad

-- | Fold the structure of a resumption using an @m@-algebra and
-- and @r@-algebra.
foldResumption :: (Monad m, Functor r) => (m a -> a) ->
  (r a -> a) -> Resumption m r a -> a
foldResumption f g (Resumption m) = f $ liftM (iter g) m

-- | Fold the structure of a resumption by interpreting each layer
-- as a computation in a monad @k@ and then @'join'@-ing the
-- layers.
interpResumption :: (Functor k, Monad k) =>
  (forall x. m x -> k x) -> (forall x. r x -> k x) ->
  Resumption m r a -> k a
interpResumption f g (Resumption m) = f m >>= foldFree g

-- | Unwrap the first layer of the \"free\" part of the resumption
-- monad and transform it using a natural transformation.
foldFirstLayer :: (RModule m r) =>
  -- The natural transformation used to transform the outer monad
  -- and the first layer of the free structure. The @'Left'@
  -- case is used when the free strucutre has no layers (= it is
  -- equal to @'Pure' a@.
  (forall x. m (Either x (r x)) -> f x) ->
  Resumption m r a ->
  f (Free r a)
foldFirstLayer f (Resumption m) = f $ liftM aux m
 where
  aux (Free r) = Right r
  aux x        = Left x

-- | Unwrap the first layer of the \"free\" part of the resumption
-- monad and transform it using a natural transformation in the
-- Kleisli category.
foldFirstLayerM :: (RModule m r) => 
  (forall x. m (r x) -> m x) ->
  Resumption m r a ->
  Resumption m r a
foldFirstLayerM f (Resumption m) = Resumption $ m >>= aux
 where
  aux (Free r) = f $ return r
  aux x        = return x

-- | Unfold structure step-by-step.
unfoldResumption :: (RModule m r) => (s -> m (Either a (r s))) ->
  s -> Resumption m r a
unfoldResumption f s = Resumption $ liftM aux $ f s
 where
  aux (Left a)  = Pure a
  aux (Right r) = Free $ r |>>= (liftM aux . f)

-- | Produce a new level of free structure using the monadic part.
splitHead :: (RModule m r, RModule k r) => (forall x. m x -> k (r x)) -> Resumption m r a -> Resumption k r a
splitHead f (Resumption r) = Resumption $ liftM Free $ f r

--
-- FM
--

-- $moggiR
-- In a paper /An Abstract View of Programming Languages/
-- E. Moggi presented a monad that in Haskell could be implemented
-- as follows (assume @m@ to be a monad, and @f@ to be a functor):
--
-- @newtype Res f m a = Res (m ('Either' a (f (Res f m a))))@
--
-- It could be shown that Moggi's monad corresponds to the
-- @'Resumption'@ monad for a module given by @'FM'@
--
-- Moggi's monad is sometimes called the /free monad transformer/
-- and is used, for example, in the @pipes@ package.

-- | A composition of a functor @f@ and a monad @m@. It is a module
-- over @m@.
--
-- In fact, it is the free module in the category of modules over
-- @m@ generated by @f@. So @'FM'@ can stand for \"composition
-- of @f@ and @m@\", or \"free module\".
newtype FM f m a = FM { unFM :: f (m a) }

instance (Functor f, Monad m) => Functor (FM f m) where
  fmap h (FM f) = FM $ fmap (liftM h) f

instance (Functor f, Monad m) => RModule m (FM f m) where
  FM f |>>= g = FM $ fmap (>>= g) f

instance (Functor f, Monad m, Foldable f, Foldable m) =>
  Foldable (FM f m)
 where
  foldMap h = foldMap id . fmap (foldMap h) . unFM

instance (Monad m, Traversable f, Traversable m) =>
  Traversable (FM f m)
 where
  traverse h (FM f) = fmap FM $ traverse (traverse h) f

--
-- MOGGI'S RESUMPTION
--

-- | A wrapper for resumptions a la Moggi.
newtype MoggiResumption f m a =
  MoggiR { unMoggiR :: Resumption m (FM f m) a}
 deriving (Functor, Monad, Applicative, Apply, Bind)

instance (Monad m, Functor f, Foldable f, Foldable m) =>
  Foldable (MoggiResumption f m)
 where
  foldMap h (MoggiR (Resumption m)) =
    foldMap id $ liftM (foldMap h) m

instance (Monad m, Traversable f, Traversable m) =>
  Traversable (MoggiResumption f m)
 where
  traverse h (MoggiR r) = fmap MoggiR $ traverse h r

instance (Functor f) => MonadTrans (MoggiResumption f) where
  lift = MoggiR . liftMonad

-- | Get one level of computation out of a resumption. Inverse of
-- @'hold'@.
force :: (Functor f, Monad m) => MoggiResumption f m a ->
  m (Either a (f (MoggiResumption f m a)))
force (MoggiR (Resumption m)) = liftM aux m
 where
  aux (Pure a) = Left a 
  aux (Free (FM f)) =
    Right $ fmap (MoggiR . Resumption) f
 
-- | Hold a computation and store it in a resumption. Inverse of
-- @'force'@.
hold :: (Functor f, Monad m) =>
  m (Either a (f (MoggiResumption f m a))) -> MoggiResumption f m a
hold m = MoggiR $ Resumption $ liftM aux m
 where
  aux (Left a)  = Pure a
  aux (Right f) = Free $ FM $ fmap (unResumption . unMoggiR) f

-- | Run a monad morphism and (any) natural transformation through 
-- the structure.
hoistMoggiR :: (Functor f, Functor t, Monad m, Monad n) =>
  (forall x. f x -> t x) -> (forall x. m x -> n x) ->
  MoggiResumption f m a -> MoggiResumption t n a
hoistMoggiR g h (MoggiR r) = MoggiR $
  hoistResumption h (FM . g . fmap h . unFM) r

toFM :: (Functor f, Monad m) => f a -> FM f m a
toFM = FM . fmap return 

foldFM :: (Functor f) => (f a -> a) -> (m a -> a) -> FM f m a -> a
foldFM g h (FM f) = g $ fmap h f

-- | Fold the structure of a Moggi resumption using an @f@-algebra
-- and an @m@-algebra.
foldMoggiR :: (Functor f, Monad m) => (f a -> a) -> (m a -> a) ->
  MoggiResumption f m a -> a
foldMoggiR g h = foldResumption h (foldFM g h) . unMoggiR

interpFM :: (Monad k) => (forall x. f x -> k x) ->
  (forall x. m x -> k x) -> FM f m a -> k a 
interpFM g h (FM f) = g f >>= h

-- | Fold the structure of a resumption by interpreting each layer
-- as a computation in a monad @k@ and then @'join'@-ing the
-- layers.
interpMoggiR :: (Functor k, Monad k) => (forall x. f x -> k x) ->
  (forall x. m x -> k x) -> MoggiResumption f m a -> k a
interpMoggiR g h = interpResumption h (interpFM g h) . unMoggiR

-- | Unfold structure step-by-step.
unfoldMoggiR :: (Functor f, Monad m) =>
  (s -> m (Either a (f s))) -> s -> MoggiResumption f m a
unfoldMoggiR f = MoggiR . unfoldResumption (liftM (fmap toFM) . f)

-- | A wrapper for resumptions based on the right-regular
-- representation module.
type RRRResumption = MoggiResumption Identity

-- | Run a resumption as a single computation
retractRRRR :: (Functor m, Monad m) => RRRResumption m a -> m a
retractRRRR = interpMoggiR (return . runIdentity) id
