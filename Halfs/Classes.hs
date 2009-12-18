{-# LANGUAGE MultiParamTypeClasses, GeneralizedNewtypeDeriving,
             FunctionalDependencies, FlexibleContexts,
             FlexibleInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Halfs.Classes
  ( HalfsCapable
  , Lockable(..)
  , Reffable(..)
  , TimedT(..)
  , Timed(..)
  , Bitmapped(..)
  , IOLock
  )
 where

import Control.Applicative
import Control.Concurrent.MVar
import Control.Exception
import Control.Monad.Reader
import Control.Monad.ST
import Data.Array.IO
import Data.Array.ST
import Data.IORef
import Data.Ratio (numerator)
import Data.Serialize
import Data.Serialize.Get
import Data.Serialize.Put
import Data.STRef
import Data.Time.Clock
import Data.Word

-- ----------------------------------------------------------------------------

-- Any monad used in Halfs must implement the following interface:
class (Bitmapped b m, Timed t m, Reffable r m, Lockable l m, Serialize t, Functor m, Monad m) =>
   HalfsCapable b t r l m | m -> b t r l

instance HalfsCapable (IOUArray Word64 Bool)   UTCTime IORef     IOLock IO
instance HalfsCapable (STUArray s Word64 Bool) Word64  (STRef s) ()     (ST s)

-- |A monad implementing Timed implements a monotonic clock that can be read
-- from. One obvious implementation is using the system clock. Another might be
-- a step counter.
class (Monad m, Eq t, Ord t) => Timed t m | m -> t where
  getTime :: m t

-- |This is a monad transformer for the Timed monad, which will work for 2^64
-- steps of an arbitrary underlying monad.
newtype TimedT m a = TimedT { runTimerT :: Word64 -> m a }

ttGetTime :: Monad m => TimedT m Word64
ttGetTime = TimedT $ \ t -> return t

instance Monad m => Monad (TimedT m) where
  return a = TimedT $ \ _ -> return a
  m >>= k  = TimedT $ \ t -> do
               a <- runTimerT m t
               runTimerT (k a) (t + 1)

instance Serialize UTCTime where
  put x = do
    putWord64be $ fromIntegral $ fromEnum $ utctDay x
    putWord64be $
      -- We have no way to extract the underlying fixed-precision Integer from
      -- the DiffTime, but picosecond resolution for DiffTime documented, so we
      -- scale via conversion to Rational (i.e., we reconstruct the underlying
      -- fixed-precision Integer).  The assert is simply in case the underlying
      -- representation changes at some point in the future.
      let dt2pico = numerator . (1000000000000*) . toRational
          off     = fromIntegral $ dt2pico $ utctDayTime x
      in assert (off >= (minBound :: Word64) && off <= (maxBound :: Word64)) off

  get = do
    UTCTime
    <$> (toEnum . fromIntegral)                `fmap` getWord64be
    <*> (picosecondsToDiffTime . fromIntegral) `fmap` getWord64be

instance Timed UTCTime IO where
  getTime = getCurrentTime

instance Timed Word64 (ST s) where
  getTime = undefined

instance Monad m => Timed Word64 (TimedT m) where
  getTime = ttGetTime

-- ---------------------------------------------------------------------------

-- |A monad implementing Reffable implements a reference type that allows for
-- mutable state.
class Monad m => Reffable r m | m -> r where
  newRef    :: a -> m (r a)
  readRef   :: r a -> m a
  writeRef  :: r a -> a -> m ()
  modifyRef :: r a -> (a -> a) -> m ()
  modifyRef r f = readRef r >>= writeRef r . f

instance Reffable (STRef s) (ST s) where
  newRef   = newSTRef
  readRef  = ($!) readSTRef
  writeRef = ($!) writeSTRef

instance Reffable IORef IO where
  newRef   = newIORef
  readRef  = ($!) readIORef
  writeRef = ($!) writeIORef

-- ---------------------------------------------------------------------------

-- |A monad implementing locks.
class Monad m => Lockable l m | m -> l where
  newLock  :: m l
  lock     :: l -> m ()
  release  :: l -> m ()

instance Lockable () (ST s) where
  newLock   = return ()
  lock _    = return ()
  release _ = return ()

newtype IOLock = IOLock (MVar ())

instance Lockable IOLock IO where
  newLock            = IOLock `fmap` newMVar ()
  lock (IOLock l)    = takeMVar l
  release (IOLock l) = putMVar l ()

-- ---------------------------------------------------------------------------

-- | A monad implementing a bitmap
class Monad m => Bitmapped b m | m -> b where
  newBitmap :: Word64 -> Bool -> m b
  clearBit  :: b -> Word64 -> m ()
  setBit    :: b -> Word64 -> m ()
  checkBit  :: b -> Word64 -> m Bool
  toList    :: b -> m [Bool]


instance Bitmapped (IOUArray Word64 Bool) IO where
  newBitmap s e = newArray (0, s - 1) e
  clearBit b i  = writeArray b i False
  setBit b i    = writeArray b i True
  checkBit      = readArray
  toList        = getElems

instance Bitmapped (STUArray s Word64 Bool) (ST s) where
  newBitmap s e = newArray (0, s - 1) e
  clearBit b i  = writeArray b i False
  setBit b i    = writeArray b i True
  checkBit      = readArray
  toList        = getElems

