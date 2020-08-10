{-# OPTIONS_GHC -fno-omit-interface-pragmas #-}

module Language.PlutusTx.Eq (Eq (..), (/=)) where

import Language.PlutusTx.Bool
import qualified Language.PlutusTx.Builtins as Builtins
import Language.PlutusTx.Data
import Prelude hiding (Eq (..), not, (&&))

{-# ANN module ("HLint: ignore" :: String) #-}

-- Copied from the GHC definition

-- | The 'Eq' class defines equality ('==').
class Eq a where
  (==) :: a -> a -> Bool

-- (/=) deliberately omitted, to make this a one-method class which has a
-- simpler representation

{-# INLINEABLE (/=) #-}
(/=) :: Eq a => a -> a -> Bool
x /= y = not (x == y)

instance Eq Integer where
  {-# INLINEABLE (==) #-}
  (==) = Builtins.equalsInteger

instance Eq Builtins.ByteString where
  {-# INLINEABLE (==) #-}
  (==) = Builtins.equalsByteString

instance Eq a => Eq [a] where
  {-# INLINEABLE (==) #-}
  [] == [] = True
  (x : xs) == (y : ys) = x == y && xs == ys
  _ == _ = False

instance Eq Bool where
  {-# INLINEABLE (==) #-}
  True == True = True
  False == False = True
  _ == _ = False

instance Eq a => Eq (Maybe a) where
  {-# INLINEABLE (==) #-}
  (Just a1) == (Just a2) = a1 == a2
  Nothing == Nothing = True
  _ == _ = False

instance (Eq a, Eq b) => Eq (Either a b) where
  {-# INLINEABLE (==) #-}
  (Left a1) == (Left a2) = a1 == a2
  (Right b1) == (Right b2) = b1 == b2
  _ == _ = False

instance Eq () where
  {-# INLINEABLE (==) #-}
  _ == _ = True

instance (Eq a, Eq b) => Eq (a, b) where
  {-# INLINEABLE (==) #-}
  (a, b) == (a', b') = a == a' && b == b'

instance Eq Data where
  {-# INLINEABLE (==) #-}
  Constr i ds == Constr i' ds' = i == i' && ds == ds'
  Constr _ _ == _ = False
  Map ds == Map ds' = ds == ds'
  Map _ == _ = False
  I i == I i' = i == i'
  I _ == _ = False
  B b == B b' = b == b'
  B _ == _ = False
  List ls == List ls' = ls == ls'
  List _ == _ = False
