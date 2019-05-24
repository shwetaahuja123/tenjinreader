{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
module Frontend.Common where

import Obelisk.Frontend
import Obelisk.Route
import Obelisk.Route.Frontend
import Reflex.Dom.Core

import Data.Text (Text)
import qualified Data.Text as T
import Data.Dependent.Sum (DSum(..))
import Control.Monad.Fix
import Data.Functor.Identity

import Common.Api
import Common.Route
import Obelisk.Generated.Static


icon :: DomBuilder t m => Text -> m ()
icon i = do
  let
    attr4 = ("aria-hidden" =: "true") <> ("class" =: ("fas " <> i))
  elAttr "i" attr4 $ return ()

btn :: DomBuilder t m => Text -> Text -> m (Event t ())
btn c t = do
  (e, _) <- elClass' "button" ("button " <> c) $ text t
  return $ domEvent Click e

btnA :: DomBuilder t m => Text -> Text -> m (Event t ())
btnA c t = do
  (e, _) <- elClass' "a" ("button " <> c) $ text t
  return $ domEvent Click e

btnIcon :: DomBuilder t m => Text -> Text -> m (Event t ())
btnIcon c i = do
  (e, _) <- elClass' "button" ("button " <> c) $
    elClass "span" "icon" $ elClass "i" ("fas " <> i) blank
  return $ domEvent Click e
