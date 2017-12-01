{-|

Script graph overlay.

-}

{-# LANGUAGE StrictData #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}

module Script.Graph (
  -- ** Static specification
  Label(..),
  Transition(..),
  validTransition,

  terminalLabel,
  initialLabel,

  -- ** Runtime state
  GraphState(..),
) where

import Protolude hiding (put, get)

import Script.Pretty
import qualified Script.Token as Token

import Data.Aeson (ToJSON(..))
import Data.Serialize (Serialize, put, get, putWord8, getWord8)
import Data.String (IsString(..))
import qualified Hash
import qualified Control.Monad

-------------------------------------------------------------------------------
-- Static Specification
-------------------------------------------------------------------------------

newtype Label = Label { unLabel :: Text }
  deriving (Eq, Show, Ord, Generic, NFData, Hashable, Hash.Hashable, ToJSON)

-- | Represents valid state flows
data Transition
  = Initial                      -- ^ Initial state
  | Step Label                   -- ^ Named state
  | Arrow Transition Transition  -- ^ State transition
  | Terminal                     -- ^ Terminal state
  deriving (Eq, Show, Generic, NFData, Serialize, Hash.Hashable)

instance Serialize Label where
  put (Label nm) = put (encodeUtf8 nm)
  get = Label . decodeUtf8 <$> get

instance IsString Label where
  fromString = Label . toS

instance Pretty Transition where
  ppr = \case
    Initial   -> token Token.initial
    Step nm   -> ppr nm
    Arrow a b -> token Token.transition <+> ppr a <+> token Token.rarrow <+> ppr b
    Terminal  -> token Token.terminal

instance Pretty Label where
  ppr (Label nm) = ppr nm

validTransition :: Transition -> Bool
validTransition = \case
  Arrow Initial a         -> True
  Arrow a Terminal        -> True
  Arrow a Initial         -> False
  Arrow Terminal a        -> False
  Arrow (Step a) (Step b) -> True

  Initial                 -> False
  Terminal                -> False
  Step _                  -> False
  Arrow _ _               -> False

-------------------------------------------------------------------------------
-- Dynamic Graph State
-------------------------------------------------------------------------------

-- | Runtime contract graph state
data GraphState
  = GraphInitial
  | GraphTerminal
  | GraphLabel Label
  deriving (Eq, Ord, Show, Generic, NFData, Hash.Hashable)

instance Pretty GraphState where
  ppr = \case
    GraphInitial   -> token Token.initial
    GraphTerminal  -> token Token.terminal
    GraphLabel lab -> ppr lab

instance Serialize GraphState where
  put = \case
    GraphInitial   -> putWord8 1
    GraphTerminal  -> putWord8 2
    GraphLabel lab -> putWord8 3 >> put lab
  get = do
    tag <- getWord8
    case tag of
      1 -> pure GraphInitial
      2 -> pure GraphTerminal
      3 -> GraphLabel <$> get
      _ -> Control.Monad.fail "Invalid graph element serialization"

instance ToJSON GraphState where
  toJSON gstate = case gstate of
    GraphInitial         -> let (Label initial) = initialLabel in toJSON initial
    GraphLabel (Label l) -> toJSON l
    GraphTerminal        -> let (Label terminal) = terminalLabel in toJSON terminal

terminalLabel :: Label
terminalLabel = "terminal"

initialLabel :: Label
initialLabel = "initial"
