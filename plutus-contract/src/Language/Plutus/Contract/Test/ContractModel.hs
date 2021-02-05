-- QuickCheck model library for contracts. Builds on top of
-- Language.Plutus.Contract.Test.StateModel.

{-# LANGUAGE AllowAmbiguousTypes   #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}

module Language.Plutus.Contract.Test.ContractModel
    -- * ContractModel
    ( ModelState
    , modelState, currentSlot, balances
    , handle, contractInstanceId
    , lockedFunds
    , ContractModel(..)
    , Action(..)
    , addCommands
    -- * GetModelState
    , GetModelState(..)
    , getModelState
    , viewState
    , viewModelState
    -- * Spec monad
    , Spec
    , wait
    , waitUntil
    , forge
    , burn
    , deposit
    , withdraw
    , transfer
    , ($=), ($~)
    -- * Dynamic logic
    , DL
    , action
    , DL.anyAction
    , DL.anyActions
    , DL.anyActions_
    , DL.stopping
    , DL.weight
    , DL.getModelStateDL
    , DL.assert
    , DL.assertModel
    , DL.forAllQ
    , DL.forAllDL
    , DL.DynLogic
    , module Language.Plutus.Contract.Test.DynamicLogic.Quantify
    -- * Running properties
    , Script
    , propRunScript_
    , propRunScript
    , propRunScriptWithOptions
    ) where

import           Control.Lens
import           Control.Monad.Cont
import           Control.Monad.Freer                                 as Eff
import           Control.Monad.Freer.Log
import           Control.Monad.Freer.State
import qualified Data.Aeson                                          as JSON
import           Data.Foldable
import           Data.Map                                            (Map)
import qualified Data.Map                                            as Map
import           Data.Row                                            (Row)
import           Data.Typeable

import           Language.Plutus.Contract                            (Contract, ContractInstanceId,
                                                                      HasBlockchainActions)
import           Language.Plutus.Contract.Test
import qualified Language.Plutus.Contract.Test.DynamicLogic.Monad    as DL
import           Language.Plutus.Contract.Test.DynamicLogic.Quantify
import           Language.Plutus.Contract.Test.StateModel            hiding (Script, arbitraryAction, initialState,
                                                                      monitoring, nextState, perform, precondition,
                                                                      shrinkAction)
import qualified Language.Plutus.Contract.Test.StateModel            as StateModel
import           Language.PlutusTx.Monoid                            (inv)
import           Ledger.Slot
import           Ledger.Value                                        (Value)
import           Plutus.Trace.Emulator                               as Trace (ContractHandle, EmulatorTrace,
                                                                               activateContractWallet, chInstanceId)

import           Test.QuickCheck                                     hiding ((.&&.))
import qualified Test.QuickCheck                                     as QC
import           Test.QuickCheck.Monadic                             as QC

data ModelState state = ModelState
        { _currentSlot   :: Slot
        , _lastSlot      :: Slot
        , _balances      :: Map Wallet Value
        , _forged        :: Value
        , _walletHandles :: Map Wallet (ContractHandle (Schema state) (Err state))
        , _modelState    :: state
        }

type Script s = StateModel.Script (ModelState s)

instance Show state => Show (ModelState state) where
    show = show . _modelState   -- for now

type Handle state = ContractHandle (Schema state) (Err state)

type Spec state = Eff '[State (ModelState state)]

class ( Typeable state
      , Show state
      , Show (Command state)
      , Eq (Command state)
      , Show (Err state)
      , JSON.ToJSON (Err state)
      , JSON.FromJSON (Err state)
      ) => ContractModel state where
    data Command state
    type Schema state :: Row *
    type Err state

    arbitraryCommand :: ModelState state -> Gen (Command state)

    initialState :: state

    precondition :: ModelState state -> Command state -> Bool

    nextState :: Command state -> Spec state ()

    perform :: ModelState state -> Command state -> EmulatorTrace ()

    monitoring :: (ModelState state, ModelState state) -> Command state -> Property -> Property

    shrinkCommand :: ModelState state -> Command state -> [Command state]

makeLenses 'ModelState

class Monad m => GetModelState m where
    type StateType m :: *
    getState :: m (ModelState (StateType m))

getModelState :: GetModelState m => m (StateType m)
getModelState = _modelState <$> getState

viewState :: GetModelState m => Getting a (ModelState (StateType m)) a -> m a
viewState l = (^. l) <$> getState

viewModelState :: GetModelState m => Getting a (StateType m) a -> m a
viewModelState l = viewState (modelState . l)

runSpec :: Spec state () -> ModelState state -> ModelState state
runSpec spec s = Eff.run $ execState s spec

wait :: forall state. Integer -> Spec state ()
wait n = modify @(ModelState state) $ over currentSlot (+ Slot n)

waitUntil :: forall state. Slot -> Spec state ()
waitUntil n = modify @(ModelState state) $ over currentSlot (max n)

forge :: forall s. Value -> Spec s ()
forge v = modify @(ModelState s) $ over forged (<> v)

burn :: forall s. Value -> Spec s ()
burn = forge . inv

deposit :: forall s. Wallet -> Value -> Spec s ()
deposit w val = modify @(ModelState s) (over (balances . at w) (Just . maybe val (<> val)))

withdraw :: Wallet -> Value -> Spec s ()
withdraw w val = deposit w (inv val)

transfer :: Wallet -> Wallet -> Value -> Spec s ()
transfer fromW toW val = withdraw fromW val >> deposit toW val

($=) :: ASetter s s a b -> b -> Spec s ()
l $= x = l $~ const x

($~) :: forall s a b. ASetter s s a b -> (a -> b) -> Spec s ()
l $~ f = modify @(ModelState s) (over (modelState . l) f)

instance GetModelState (Spec s) where
    type StateType (Spec s) = s
    getState = get

handle :: ModelState s -> Wallet -> Trace.ContractHandle (Schema s) (Err s)
handle s w = s ^?! walletHandles . at w . _Just

lockedFunds :: ModelState s -> Value
lockedFunds s = s ^. forged <> inv (fold $ s ^. balances)

-- Using this function in models makes ghc choke.
-- callEndpoint ::
--     forall l s ep.
--     (ContractConstraints (Schema s), HasEndpoint l ep (Schema s)) => ModelState s -> Wallet -> ep -> EmulatorTrace ()
-- callEndpoint s w v =
--     case s ^. walletHandles . at w of
--         Nothing -> return () -- fail in some way? could add error effect on top of EmulatorTrace
--         Just h  -> Trace.callEndpoint @l @ep @(Schema s) h v

contractInstanceId :: ModelState s -> Wallet -> ContractInstanceId
contractInstanceId s w = chInstanceId $ handle s w

addCommands :: forall state. ContractModel state => Script state -> [Command state] -> Script state
addCommands (StateModel.Script s) cmds = StateModel.Script $ s ++ [Var i := ContractAction @state @() cmd | (cmd, i) <- zip cmds [n + 1..] ]
    where
        n = last $ 0 : [ i | Var i := _ <- s ]

instance ContractModel state => Show (Action (ModelState state) a) where
    showsPrec p (ContractAction a) = showsPrec p a

deriving instance ContractModel state => Eq (Action (ModelState state) a)

instance ContractModel state => StateModel (ModelState state) where

    data Action (ModelState state) a = ContractAction (Command state)

    type ActionMonad (ModelState state) = EmulatorTrace

    arbitraryAction s = do
        a <- arbitraryCommand s
        return (Some @() (ContractAction a))

    shrinkAction s (ContractAction a) = [ Some @() (ContractAction a') | a' <- shrinkCommand s a ]

    initialState = ModelState { _currentSlot   = 0
                              , _lastSlot      = 125        -- Set by propRunScript
                              , _balances      = Map.empty
                              , _forged        = mempty
                              , _walletHandles = Map.empty
                              , _modelState    = initialState }

    nextState s (ContractAction cmd) _v = runSpec (nextState cmd) s

    precondition s (ContractAction cmd) = s ^. currentSlot < s ^. lastSlot - 10 -- No commands if < 10 slots left
                                          && precondition s cmd

    perform s (ContractAction cmd) _env = error "unused" <$ perform s cmd

    postcondition _s _cmd _env _res = True

    monitoring (s0, s1) (ContractAction cmd) _env _res = monitoring (s0, s1) cmd

-- * Dynamic logic

type DL s = DL.DL (ModelState s)

action :: ContractModel s => Command s -> DL s ()
action cmd = DL.action (ContractAction @_ @() cmd)

instance ContractModel s => DL.DynLogicModel (ModelState s) where
    restricted _ = False

instance GetModelState (DL s) where
    type StateType (DL s) = s
    getState = DL.getModelStateDL

-- * Running the model

runTr :: CheckOptions -> TracePredicate -> EmulatorTrace () -> Property
runTr opts predicate trace =
  flip runCont (const $ property True) $
    checkPredicateInner opts predicate trace
                        debugOutput assertResult
  where
    debugOutput :: String -> Cont Property ()
    debugOutput out = cont $ \ k -> whenFail (putStrLn out) $ k ()

    assertResult :: Bool -> Cont Property ()
    assertResult ok = cont $ \ k -> ok QC..&&. k ()

activateWallets :: forall state.
    ( ContractModel state
    , HasBlockchainActions (Schema state)
    , ContractConstraints (Schema state)
    ) => [Wallet] -> Contract (Schema state) (Err state) () -> EmulatorTrace (Map Wallet (Handle state))
activateWallets wallets contract =
    Map.fromList . zip wallets <$> mapM (flip (activateContractWallet @(Schema state)) contract) wallets

propRunScript_ :: forall state.
    ( HasBlockchainActions (Schema state)
    , ContractConstraints (Schema state)
    , ContractModel state ) =>
    [Wallet] ->
    Contract (Schema state) (Err state) () ->
    Script state ->
    Property
propRunScript_ wallets contract script =
    propRunScript wallets contract
                  (\ _ -> pure True)
                  (\ _ -> pure ())
                  script
                  (\ _ -> pure ())

propRunScript :: forall state.
    ( HasBlockchainActions (Schema state)
    , ContractConstraints (Schema state)
    , ContractModel state ) =>
    [Wallet] ->
    Contract (Schema state) (Err state) () ->
    (ModelState state -> TracePredicate) ->
    (ModelState state -> EmulatorTrace ()) ->
    Script state ->
    (ModelState state -> PropertyM EmulatorTrace ()) ->
    Property
propRunScript = propRunScriptWithOptions (set minLogLevel Warning defaultCheckOptions)

propRunScriptWithOptions :: forall state.
    ( HasBlockchainActions (Schema state)
    , ContractConstraints (Schema state)
    , ContractModel state ) =>
    CheckOptions ->
    [Wallet] ->
    Contract (Schema state) (Err state) () ->
    (ModelState state -> TracePredicate) ->
    (ModelState state -> EmulatorTrace ()) ->
    Script state ->
    (ModelState state -> PropertyM EmulatorTrace ()) ->
    Property
propRunScriptWithOptions opts wallets contract predicate before script after =
    monadic (runTr opts finalPredicate . void) $ do
        handles <- QC.run $ activateWallets @state wallets contract
        let initState = StateModel.initialState { _walletHandles = handles
                                                , _lastSlot      = opts ^. maxSlot }
        QC.run $ before initState
        (st, _) <- runScriptInState initState script
        after st
    where
        finalState     = stateAfter script
        finalPredicate = predicate finalState .&&. checkBalances finalState

checkBalances :: ModelState state -> TracePredicate
checkBalances s = Map.foldrWithKey (\ w val p -> walletFundsChange w val .&&. p) (pure True) (s ^. balances)

