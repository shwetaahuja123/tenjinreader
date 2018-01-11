{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecursiveDo #-}
module ReadingPane where

import FrontendCommon

import qualified Data.Text as T
import qualified Data.Set as Set
import qualified Data.Map as Map
import qualified Data.List as List
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NE
import qualified Data.Vector as V
import qualified GHCJS.DOM.DOMRectReadOnly as DOM
import qualified GHCJS.DOM.Element as DOM
import qualified GHCJS.DOM.Document as DOM
import qualified GHCJS.DOM as DOM
import qualified GHCJS.DOM.Types as DOM
import qualified GHCJS.DOM.IntersectionObserverEntry as DOM hiding (getBoundingClientRect)
import qualified GHCJS.DOM.IntersectionObserverCallback as DOM
import qualified GHCJS.DOM.IntersectionObserver as DOM
import Control.Exception
import Reflex.Dom.Widget.Resize
import Language.Javascript.JSaddle.Value
import JavaScript.Object

checkOverFlow e heightDyn = do
  v <- sample $ current heightDyn
  let overFlowThreshold = fromIntegral v
  rect <- DOM.getBoundingClientRect (_element_raw e)
  trects <- DOM.getClientRects (_element_raw e)
  y <- DOM.getY rect
  h <- DOM.getHeight rect
  -- text $ "Coords: " <> (tshow y) <> ", " <> (tshow h)
  return (y + h > overFlowThreshold)

checkVerticalOverflow (ie,oe) r action = do
  rx <- DOM.getX =<< DOM.getBoundingClientRect r
  ix <- DOM.getX =<< DOM.getBoundingClientRect ie
  ox <- DOM.getX =<< DOM.getBoundingClientRect oe
  liftIO $ putStrLn $ (show (rx,ix,ox) :: Text)
  liftIO $ action $ if
    | (rx > ox && rx < ix) -> (0, Nothing) -- Outside
    | ix < rx -> (0, Just ShrinkText)
    | ox > rx -> (0, Just GrowText)
    | otherwise -> (0, Nothing) -- hidden

-- setupInterObs :: (DOM.MonadDOM m, DOM.IsElement e)
--   => (e, e)
--   -> _
--   -> ((Int, Maybe TextAdjust) -> IO ())
--   -> m DOM.IntersectionObserver
-- setupInterObs ind options action = do
--   cb <- DOM.newIntersectionObserverCallback
--     (intersectionObsCallback ind action)
--   DOM.newIntersectionObserver cb (Just options)

-- intersectionObsCallback (ie,oe) action (e:_) _  = do
--   rx <- DOM.getX =<< DOM.getRootBounds e
--   ix <- DOM.getX =<< DOM.getBoundingClientRect ie
--   ox <- DOM.getX =<< DOM.getBoundingClientRect oe
--   liftIO $ putStrLn $ (show (rx,ix,ox) :: Text)
--   liftIO $ action $ if (rx > ox && rx < ix) -- Outside
--     then (0, Nothing)
--     else if rx > ix
--             then (0, Just ShrinkText)
--             else (0, Just GrowText)

readingPane :: AppMonad t m
  => Event t (ReaderDocumentData)
  -> AppMonadT t m (Event t (), Event t (ReaderDocument CurrentDb))
readingPane docEv = do
  ev <- getPostBuild
  s <- getWebSocketResponse (GetReaderSettings <$ ev)
  v <- widgetHold (readingPaneInt docEv def)
    (readingPaneInt docEv <$> s)
  return (switchPromptlyDyn (fst <$> v)
         , switchPromptlyDyn (snd <$> v))

readerSettingsControls rsDef = divClass "form-inline" $ divClass "form-group" $ do
  let
    ddConf :: _
    ddConf = def & dropdownConfig_attributes .~ (constDyn ddAttr)
    ddAttr = ("class" =: "form-control input-sm")
  fontSizeDD <- dropdown (rsDef ^. fontSize) (constDyn fontSizeOptions) ddConf
  rubySizeDD <- dropdown (rsDef ^. rubySize) (constDyn fontSizeOptions) ddConf
  lineHeightDD <- dropdown (rsDef ^. lineHeight) (constDyn lineHeightOptions) ddConf
  writingModeDD <- dropdown (rsDef ^. verticalMode) (constDyn writingModeOptions) ddConf
  heightDD <- dropdown (rsDef ^. numOfLines) (constDyn numOfLinesOptions) ddConf
  let rsDyn = ReaderSettings <$> (value fontSizeDD) <*> (value rubySizeDD)
                <*> (value lineHeightDD) <*> (value writingModeDD)
                <*> (value heightDD)
  return rsDyn

divWrap rs fullscreenDyn w = do
  let
    divAttr = (\s l h fs -> ("style" =:
      ("font-size: " <> tshow s <>"%;"
        <> "line-height: " <> tshow l <> "%;"
        -- <> "height: " <> tshow h <> "px;"
        <> (if fs then "position: fixed;" else "")
        <> "display: block;" <> "padding: 40px;"))
           <> ("class" =: (if fs then "modal modal-content" else "")))
      <$> (_fontSize <$> rs) <*> (_lineHeight <$> rs)
      <*> (_numOfLines <$> rs) <*> (fullscreenDyn)

  elDynAttr "div" divAttr w

readingPaneInt :: AppMonad t m
  => Event t (ReaderDocumentData)
  -> ReaderSettings CurrentDb
  -> AppMonadT t m (Event t (), Event t (ReaderDocument CurrentDb))
readingPaneInt docEv rsDef = do
  closeEv <- btn "btn-default" "Close"
  -- editEv <- btn "btn-default" "Edit"
  fullScrEv <- btn "btn-default" "Full Screen"

  rsDyn <- readerSettingsControls rsDef

  getWebSocketResponse (SaveReaderSettings <$> (updated rsDyn))

  widgetHold ((text "waiting for document data"))
    -- (readingPaneView <$> docEv)
    -- (paginatedReader rsDyn fullScrEv <$> docEv)
    (verticalReader rsDyn fullScrEv <$> docEv)
  -- rdDyn <- holdDyn Nothing (Just <$> docEv)
  return (closeEv, never)
         -- , fmapMaybe identity $ tagDyn rdDyn editEv)

-- Display the complete document in one page
readingPaneView :: AppMonad t m
  => (ReaderDocument CurrentDb)
  -> AppMonadT t m ()
readingPaneView (ReaderDocument _ title annText _) = do
  fontSizeDD <- dropdown 100 (constDyn fontSizeOptions) def
  rubySizeDD <- dropdown 120 (constDyn fontSizeOptions) def
  lineHeightDD <- dropdown 150 (constDyn lineHeightOptions) def
  let divAttr = (\s l -> "style" =: ("font-size: " <> tshow s <>"%;"
        <> "line-height: " <> tshow l <> "%;"))
        <$> (value fontSizeDD) <*> (value lineHeightDD)

  rec
    let
      -- vIdEv :: Event t ([VocabId], Text)
      vIdEv = leftmost $ V.toList vIdEvs

    vIdDyn <- holdDyn [] (fmap fst vIdEv)

    vIdEvs <- elDynAttr "div" divAttr $ do
      rec
        (resEv,v) <- resizeDetector $ do
          el "h3" $ text title
          V.mapM (renderOnePara vIdDyn (value rubySizeDD)) annText
      return v

  divClass "" $ do
    detailsEv <- getWebSocketResponse $ GetVocabDetails
      <$> (fmap fst vIdEv)
    surfDyn <- holdDyn ("", Nothing) (fmap snd vIdEv)
    showVocabDetailsWidget (attachDyn surfDyn detailsEv)
  return ()

-- Remove itself on prev page click

-- renderParaWrap ::
--      forall t m b . (AppMonad t m)
--   => Dynamic t (ReaderSettingsTree CurrentDb)
--   -> Event t b
--   -> Dynamic t [VocabId]
--   -> Dynamic t [(Int,AnnotatedPara)]
--   -> (AppMonadT t m () -> AppMonadT t m (Event t ()))
--   -> Dynamic t (Map Text Text)
--   -> Int
--   -> AppMonadT t m (Dynamic t ( (Event t (), Event t ())
--                               , (Event t Int, Event t ([VocabId], Text))))

-- renderParaWrap rs prev vIdDyn textContent dispFullScr divAttr paraNum =
--   widgetHold (renderFromPara paraNum)
--     ((return nVal) <$ prev)
--   where
--     nVal = ((never,never), (never, never))

--     renderParaNum 0 paraNum resizeEv = return (never,never)
--     renderParaNum paraCount paraNum resizeEv = do
--       cntnt <- sample $ current textContent
--       let para = List.lookup paraNum cntnt
--       case para of
--         Nothing -> text "--- End of Text ---" >> return (never, never)
--         (Just p) -> renderPara paraCount p paraNum resizeEv

--     renderPara paraCount para paraNum resizeEv = do
--       (e,v1) <- el' "div" $
--         renderOnePara vIdDyn (_rubySize <$> rs) para

--       ev <- delay 0.2 =<< getPostBuild
--       overFlowEv <- holdUniqDyn
--         =<< widgetHold (checkOverFlow e (_numOfLines <$> rs))
--         (checkOverFlow e (_numOfLines <$> rs)
--            <$ (leftmost [ev,resizeEv]))
--       -- display overFlowEv

--       let
--         nextParaWidget b = if b
--           then do
--              (e,_) <- elAttr' "button" rightBtnAttr $ text ">"
--              return ((paraNum + 1) <$ domEvent Click e, never)
--           else renderParaNum (paraCount - 1) (paraNum + 1) resizeEv

--       v2 <- widgetHold (nextParaWidget False)
--             (nextParaWidget <$> updated overFlowEv)
--       return $ (\(a,b) -> (a, leftmost [v1,b]))
--         (switchPromptlyDyn $ fst <$> v2
--         , switchPromptlyDyn $ snd <$> v2)

--     btnCommonAttr stl = ("class" =: "btn btn-xs")
--        <> ("style" =: ("height: 80%; top: 10%; width: 20px; position: absolute;"
--           <> stl ))
--     leftBtnAttr = btnCommonAttr "left: 10px;"
--     rightBtnAttr = btnCommonAttr "right: 10px;"
--     renderFromPara :: (_) => Int
--       -> AppMonadT t m ((Event t () -- Close Full Screen
--                        , Event t ()) -- Previous Page
--       , (Event t Int, Event t ([VocabId], Text)))
--     renderFromPara startPara = do
--       rec
--         (resizeEv,v) <- resizeDetector $ elDynAttr "div" divAttr $ do
--           (e,_) <- elClass' "button" "close" $
--             dispFullScr (text "Close")
--           prev <- if startPara == 0
--             then return never
--             else do
--               (e,_) <- elAttr' "button" leftBtnAttr $ text "<"
--               return (domEvent Click e)
--           v1 <- renderParaNum 20 startPara resizeEv
--           return ((domEvent Click e, prev), v1)
--       return v


-- Auto paginate text
--   - Split large para into different pages
--   - Small para move to next page
-- Forward and backward page turn buttons
-- Jump to page
-- variable height / content on page
-- store the page number (or para number) and restore progress
-- Bookmarks
-- paginatedReader :: forall t m . AppMonad t m
--   => Dynamic t (ReaderSettings CurrentDb)
--   -> Event t ()
--   -> (ReaderDocumentData)
--   -> AppMonadT t m ()
-- paginatedReader rs fullScrEv (docId, title, (startPara, _), annText) = do
--   -- render one para then see check its height

--   rec
--     let
--       dispFullScr m = do
--         dyn ((\fs -> if fs then m else return ()) <$> fullscreenDyn)

--       divAttr = (\s l h fs -> ("style" =:
--         ("font-size: " <> tshow s <>"%;"
--           <> "line-height: " <> tshow l <> "%;"
--           -- <> "height: " <> tshow h <> "px;"
--           <> (if fs then "position: fixed;" else "")
--           <> "display: block;" <> "padding: 40px;"))
--              <> ("class" =: (if fs then "modal modal-content" else "")))
--         <$> (_fontSize <$> rs) <*> (_lineHeight <$> rs)
--         <*> (_numOfLines <$> rs) <*> (fullscreenDyn)


--       vIdEv = switchPromptlyDyn (snd . snd <$> val)
--       fullScrCloseEv = switchPromptlyDyn (fst . fst <$> val)

--       val = join valDDyn
--       newPageEv :: Event t Int
--       newPageEv = leftmost [switchPromptlyDyn (fst . snd <$> val), firstPara]

--     vIdDyn <- holdDyn [] (fmap fst vIdEv)
--     fullscreenDyn <- holdDyn False (leftmost [ True <$ fullScrEv
--                                              , False <$ fullScrCloseEv])

--     firstParaDyn <- holdDyn startPara newPageEv
--     let lastAvailablePara = ((\(p:_) -> fst p) . reverse) <$> textContent
--         firstAvailablePara = ((\(p:_) -> fst p)) <$> textContent
--         hitEndEv = fmapMaybe hitEndF (attachDyn lastAvailablePara newPageEv)
--         hitEndF (l,n)
--           | l - n < 10 = Just (l + 1)
--           | otherwise = Nothing
--         hitStartEv = fmapMaybe hitStartF (attachDyn firstAvailablePara firstPara)
--         hitStartF (f,n)
--           | n - f < 10 = Just (max 0 (f - 30))
--           | otherwise = Nothing

--     moreContentEv <- getWebSocketResponse $
--       (\p -> ViewDocument docId (Just p)) <$> (leftmost [hitEndEv, hitStartEv])

--     display firstParaDyn
--     text ", "
--     display lastAvailablePara
--     text ", "
--     display (length <$> textContent)
--     -- Keep at most 60 paras in memory, length n == 30
--     let
--     textContent <- foldDyn moreContentAccF annText ((\(_,_,_,c) -> c) <$>
--                                     (fmapMaybe identity moreContentEv))

--     -- Temporary render to find firstPara
--     let prev = switchPromptlyDyn (snd . fst <$> val)
--     firstPara <- (getFirstParaOfPrevPage rs prev vIdDyn textContent dispFullScr divAttr
--       ((\p -> max 0 (p - 1)) <$> tagDyn firstParaDyn prev))

--     let renderParaF = renderParaWrap rs prev vIdDyn textContent dispFullScr divAttr
--     -- Render Actual content
--     valDDyn <- widgetHold (renderParaF startPara)
--       (renderParaF <$> newPageEv)

--   divClass "" $ do
--     detailsEv <- getWebSocketResponse $ GetVocabDetails
--       <$> (fmap fst vIdEv)
--     surfDyn <- holdDyn "" (fmap snd vIdEv)
--     showVocabDetailsWidget (attachDyn surfDyn detailsEv)

--   getWebSocketResponse ((\p -> SaveReadingProgress docId (p,Nothing)) <$> newPageEv)
--   return ()


getFirstParaOfPrevPage ::
     forall t m b . (AppMonad t m)
  => Dynamic t (ReaderSettingsTree CurrentDb)
  -> Event t b
  -> Dynamic t [VocabId]
  -> Dynamic t [(Int,AnnotatedPara)]
  -> (AppMonadT t m () -> AppMonadT t m (Event t ()))
  -> Dynamic t (Map Text Text)
  -> Event t Int
  -> AppMonadT t m (Event t Int)
getFirstParaOfPrevPage rs prev vIdDyn textContent dispFullScr divAttr endParaEv = do
  rec
    let
      init endPara = do
        elDynAttr "div" divAttr $ do
          rec
            (e,v) <- el' "div" $
              bwdRenderParaNum 20 endPara e
          return v -- First Para

      -- Get para num and remove self
      getParaDyn endPara = do
        widgetHold (init endPara)
          ((return (constDyn 0)) <$ delEv)

    delEv <- delay 2 endParaEv
  pDyn <- widgetHold (return (constDyn (constDyn 0)))
    (getParaDyn <$> endParaEv)
  return (tagDyn (join $ join pDyn) delEv)
  where
    bwdRenderParaNum 0 paraNum e = return (constDyn paraNum)
    bwdRenderParaNum paraCount paraNum e = do
      cntnt <- sample $ current textContent
      let para = List.lookup paraNum cntnt
      case para of
        Nothing -> return (constDyn 0)
        (Just p) -> bwdRenderPara paraCount p paraNum e


    bwdRenderPara paraCount para paraNum e = do
      ev <- delay 0.1 =<< getPostBuild
      overFlowEv <- holdUniqDyn
        =<< widgetHold (return True)
        (checkOverFlow e (_numOfLines <$> rs) <$ ev)

      let
        prevParaWidget b = if b
          then return (constDyn paraNum)
          else bwdRenderParaNum (paraCount - 1) (paraNum - 1) e

      v2 <- widgetHold (prevParaWidget True)
            (prevParaWidget <$> updated overFlowEv)

      el "div" $
        renderOnePara vIdDyn (_rubySize <$> rs) para

      return $ join v2

-- Algo
-- Start of page
  -- (ParaId, Maybe Offset) -- (Int , Maybe Int)

-- How to determine the
-- End of page
  -- (ParaId, Maybe Offset)

-- Get the bounding rect of each para
-- if Y + Height > Div Height then para overflows
-- Show the para in next page

----------------------------------------------------------------------------------
-- Vertical rendering


verticalReader :: forall t m . AppMonad t m
  => Dynamic t (ReaderSettings CurrentDb)
  -> Event t ()
  -> (ReaderDocumentData)
  -> AppMonadT t m ()
verticalReader rs fullScrEv (docId, title, startParaMaybe, annText) = do
  (evVisible, action) <- newTriggerEvent

  visDyn <- holdDyn (0,Nothing) evVisible
  display visDyn

  let
    divAttr' = (\s l h fs -> ("style" =:
      ("font-size: " <> tshow s <>"%;"
        <> "line-height: " <> tshow l <> "%;"
        <> "height: " <> (if fs then "100%;" else tshow h <> "px;")
        <> "width: " <> (if fs then "100%;" else "80vw;")
        <> "writing-mode: vertical-rl;"
        <> "word-wrap: break-word;"
        -- <> (if fs then "position: fixed;" else "")
        <> "display: block;" <> "padding: 40px;"))
           <> ("class" =: (if fs then "modal modal-content" else "")))
      <$> (_fontSize <$> rs) <*> (_lineHeight <$> rs)
      <*> (_numOfLines <$> rs)

    btnCommonAttr stl = ("class" =: "btn btn-xs")
       <> ("style" =: ("height: 80%; top: 10%; width: 20px; position: absolute; z-index: 1060;"
          <> stl ))
    leftBtnAttr = btnCommonAttr "left: 10px;"
    rightBtnAttr = btnCommonAttr "right: 10px;"
    startPara = (\(p,v) -> (p,maybe 0 identity v)) startParaMaybe
    initState = getState (getCurrentViewContent (annText, startPara))
    getState content = maybe ((0,1), []) (\p -> ((0,length $ snd p), [p])) $
      headMay content

  -- Buttons
  prev <- if False
    then return never
    else do
      (e,_) <- elAttr' "button" rightBtnAttr $ text ">"
      return (domEvent Click e)
  next <- if False
    then return never
    else do
      (e,_) <- elAttr' "button" leftBtnAttr $ text "<"
      return (domEvent Click e)

  --------------------------------
  rec
    let
      dEv = snd <$> (evVisible)
      newPageEv' :: Event t (Int,Int)
      newPageEv' = fmapMaybe identity $ leftmost
        [tagDyn nextParaMaybe next
        , Just <$> firstPara] -- TODO

      lastDisplayedPara :: Dynamic t (Int, Int)
      lastDisplayedPara = (\v (fpN,o) -> maybe (0,0)
        (\(pn,pt) -> (pn, (if fpN == pn then o - 1 else 0) + length pt))
        (preview (_2 . to reverse . _head) v)) <$> row1Dyn <*> firstParaDyn


    nextParaMaybe <- combineDyn getNextParaMaybe lastDisplayedPara textContent
    prevParaMaybe <- combineDyn getPrevParaMaybe firstParaDyn textContent

    newPageEv <- delay 1 newPageEv'
    firstParaDyn <- holdDyn startPara newPageEv

    -- textContentInThisView has relative numbering for first para, wrt to the start point
    textContentInThisView <- holdDyn (getCurrentViewContent (annText, startPara))
      (getCurrentViewContent <$> attachDyn textContent newPageEv)

    let foldF st = foldDyn textAdjustF st (attachDyn textContentInThisView dEv)
        newStateEv = getState <$> (updated textContentInThisView)
        row1Dyn :: Dynamic t ((Int,Int), [(Int,AnnotatedPara)])
        row1Dyn = join row1Dyn'

    (row1Dyn') <- widgetHold (foldF initState) (foldF <$> newStateEv)


    textContent <- fetchMoreContentF docId annText firstPara newPageEv

    -- Reverse render widget for finding first para of prev page
    -- Find the para num (from start) which is visible completely
    let
      divAttr = divAttr' <*> (constDyn False)
      renderBackWidget :: _ -> AppMonadT t m (Event t (Int,Int))
      renderBackWidget = renderVerticalBackwards rs divAttr
      prevPageEv :: Event t (Int,Int)
      prevPageEv = fmapMaybe identity (tagDyn prevParaMaybe prev)

    textContentInPreviousView <- holdDyn (getPrevViewContent (annText, startPara))
      (getPrevViewContent <$> attachDyn textContent newPageEv)

    firstPara <- widgetHoldWithRemoveAfterEvent
      (renderBackWidget <$> attachDyn textContentInPreviousView prevPageEv)

  text "firstParaDyn:"
  display firstParaDyn
  text " lastDisplayedPara:"
  display lastDisplayedPara
  text " nextParaMaybe:"
  display nextParaMaybe
  text " prevParaMaybe:"
  display prevParaMaybe

  --------------------------------
  (resizeEv, (rowRoot, (inside, outside, vIdEv, closeEv))) <- resizeDetector $ do
    rec
      let
        divAttr = divAttr' <*> fullscreenDyn

        wrapDynAttr = ffor fullscreenDyn $ \b -> if b
          then ("style" =: "position: fixed; top: 0; bottom: 0; left: 0; right: 0;")
          else Map.empty

        closeEv = tup ^. _2 . _4
        dispFullScr m = do
          dyn ((\fs -> if fs then m else return ()) <$> fullscreenDyn)

      fullscreenDyn <- holdDyn False (leftmost [ True <$ fullScrEv
                                             , False <$ closeEv])
      tup <- elDynAttr "div" wrapDynAttr $ elDynAttr' "div" divAttr $ do
        closeEv <- do
          (e,_) <- elClass' "button" "close" $ do
            dispFullScr (text "Close")
          return (domEvent Click e)

        vIdEv <- el "div" $ do
          renderDynParas rs (snd <$> row1Dyn)

        (inside, _) <- elAttr' "div" ("style" =: "height: 1em; width: 1em;") $ do
          text ""
        elAttr "div" ("style" =: "height: 2em; width: 2em;") $ do
          text ""
        (outside, _) <- elAttr' "div" ("style" =: "height: 1em; width: 1em;") $ do
          text ""
          return ()
        return (inside, outside, vIdEv, closeEv)
    return tup

  divClass "" $ do
    detailsEv <- getWebSocketResponse $ GetVocabDetails
      <$> (fmap fst vIdEv)
    surfDyn <- holdDyn ("", Nothing) (fmap snd vIdEv)
    showVocabDetailsWidget (attachDyn surfDyn detailsEv)

  getWebSocketResponse ((\(p,o) -> SaveReadingProgress docId (p,Just o)) <$> newPageEv)

  --------------------------------

  -- v <- liftJSM $ do
  --   o <- create
  --   m <- toJSVal (0.9 :: Double)
  --   t <- toJSVal (1 :: Double)
  --   r <- toJSVal (_element_raw rowRoot)
  --   setProp "root" r o
  --   setProp "margin" m o
  --   setProp "threshold" t o
  --   toJSVal (ValObject o)

  let inEl = _element_raw inside
      outEl = _element_raw outside
  -- io <- setupInterObs (inEl, outEl) (DOM.IntersectionObserverInit v) action
  -- DOM.observe io inEl
  -- DOM.observe io outEl

  time <- liftIO $ getCurrentTime

  let
    -- TODO Stop if we hit end of text, close the document
      stopTicks = fmapMaybe (\(_,a) -> if isNothing a then Just () else Nothing) evVisible
      startTicksAgain = leftmost [() <$ updated rs
                                 , resizeEv
                                 , closeEv, fullScrEv
                                 , () <$ newPageEv]
      ticksWidget = do
        let init = widgetHold (tickLossy 1 time)
              (return never <$ stopTicks)
        t <- widgetHold init
          (init <$ startTicksAgain)
        return (switchPromptlyDyn $ join t)

  tickEv <- ticksWidget

  performEvent (checkVerticalOverflow (inEl, outEl)
                (_element_raw rowRoot) action <$ tickEv)

  return ()

fetchMoreContentF :: (AppMonad t m)
  => _
  -> [(Int,AnnotatedPara)]
  -> Event t (Int,Int)
  -> Event t (Int,Int)
  -> AppMonadT t m (Dynamic t [(Int,AnnotatedPara)])
fetchMoreContentF docId annText firstPara newPageEv = do
  rec
    -- Fetch more contents
    -- Keep at most 60 paras in memory, length n == 30
    let

        lastAvailablePara = ((\(p:_) -> fst p) . reverse) <$> textContent
        firstAvailablePara = ((\(p:_) -> fst p)) <$> textContent
        hitEndEv = fmapMaybe hitEndF (attachDyn lastAvailablePara newPageEv)
        hitEndF (l,(n,_))
          | l - n < 10 = Just (l + 1)
          | otherwise = Nothing
        hitStartEv = fmapMaybe hitStartF (attachDyn firstAvailablePara firstPara)
        hitStartF (f,(n,_))
          | n - f < 10 = Just (max 0 (f - 30))
          | otherwise = Nothing

    moreContentEv <- getWebSocketResponse $
      (\p -> ViewDocument docId (Just p)) <$> (leftmost [hitEndEv, hitStartEv])

    textContent <- foldDyn moreContentAccF annText ((\(_,_,_,c) -> c) <$>
                                    (fmapMaybe identity moreContentEv))

  text "("
  display lastAvailablePara
  text ", "
  display firstAvailablePara
  text ", "
  display (length <$> textContent)
  text ")"

  return textContent

moreContentAccF :: [(Int, AnnotatedPara)] -> [(Int, AnnotatedPara)] -> [(Int, AnnotatedPara)]
moreContentAccF [] o = o
moreContentAccF n@(n1:_) o@(o1:_)
  | (fst n1) > (fst o1) = (drop (length o - 30) o) ++ n -- More forward content
  | otherwise = n ++ (take 30 o) -- More previous paras

getCurrentViewContent :: ([(Int,AnnotatedPara)], (Int, Int))
  -> [(Int,AnnotatedPara)]
getCurrentViewContent (annText, (p,o)) = startP : restP
  where
    startP = (p, maybe [] (drop (o - 1)) (List.lookup p annText))
    restP = filter ((> p) . fst) annText

-- Offsets are the Current start of page
getPrevViewContent :: ([(Int,AnnotatedPara)], (Int, Int))
  -> [(Int,AnnotatedPara)]
getPrevViewContent (annText, (p,o)) =
  if o == 0 then restP else reverse $ lastP : (reverse restP)
  where
    lastP = (p, maybe [] (take (o - 1)) (List.lookup p annText))
    restP = filter ((< p) . fst) annText

-- Start of next page (one after end of current page)
getNextParaMaybe :: (Int, Int) -> [(Int,AnnotatedPara)]
  -> Maybe (Int, Int)
getNextParaMaybe (lp, lpOff) textContent = lpOT >>= \l ->
  case (drop lpOff l, nextP) of
    ([],Nothing) -> Nothing
    ([],Just _) -> Just (lp + 1, 0)
    (ls,_) -> Just $ (lp,lpOff + 1)
  where
    lpOT = List.lookup lp textContent
    nextP = List.lookup (lp + 1) textContent

-- End of previous page (one before start of current page)
getPrevParaMaybe :: (Int, Int) -> [(Int,AnnotatedPara)]
  -> Maybe (Int,Int)
getPrevParaMaybe (lp, lpOff) textContent =
  case (lpOff, prevP) of
    (0,Just p) -> Just $ (lp - 1, length p)
    (0, Nothing) -> Nothing
    (_,_) -> Just (lp, lpOff - 1 )
  where
    prevP = List.lookup (lp - 1) textContent

data TextAdjust = ShrinkText | GrowText
  deriving (Show, Eq)


-- Converge on the text content size based on Events
-- The Input events will toggle between shrink and grow
-- This is equivalent to binary space search.
-- Keep track of low and upper bound
-- lower bound causes Grow event, upper bound causes Shrink event
-- Do binary search between these bounds
-- When a resize occurs (ie event goes Nothing -> Just)
-- The bounds will have to be re-calculated

-- (li,ui) are wrt to the content given in the annText
-- Therefore the annText is limited only to the content which has to be
-- displayed in this view (> first char for normal, < Last Char for reverse)
textAdjustF
  :: ([(Int,AnnotatedPara)], Maybe TextAdjust)
  -> ((Int,Int), [(Int,AnnotatedPara)])
  -> ((Int,Int), [(Int,AnnotatedPara)])

-- lp -> last para
-- ps -> all paras
-- lpN -> last para number
-- lpT -> last para Content
textAdjustF (annText, (Just ShrinkText)) v@(_,[]) = v
textAdjustF (annText, (Just ShrinkText)) ((li,ui), ps)
  = case (lp) of
      (_,[]) -> case psRev of
        (lp':psRev') -> textAdjustF (annText, (Just ShrinkText))
          ((0,length lp'), (reverse psRev))
        [] -> ((0,1),[])

      (lpN,lpT) -> ((liN, lenT) -- Adjust upper bound
          , (reverse psRev) ++ [(lpN, nlpT)])
        where (liN,halfL) = if li < lenT
                then (,) li (li + (floor $ (fromIntegral (lenT - li)) / 2))
                else (,) 0 (floor $ (fromIntegral lenT) / 2)
              nlpT = take halfL lpT
              lenT = length lpT
  where
    (lp:psRev) = reverse ps

textAdjustF (annText, (Just GrowText)) v@(_,[])
  = maybe v (\p -> ((0, length $ snd p), [p])) $ headMay annText

textAdjustF (annText, (Just GrowText)) v@((li,ui), ps) =
  (\(i,n) -> (i, (reverse psRev) ++ n)) newLp
  where
    ((lpN, lpT):psRev) = reverse ps
    newLp = if lenT < lenOT
      -- Add content from this para
      -- Adjust lower bound
      then (,) (lenT, uiN) [(lpN, lpTN)]
      -- This para content over, add a new Para
      else case newPara of
             Just np -> (,) (0, length np) $ (lpN, lpT): [(lpN + 1, np)] -- not reversed, so add at end
             Nothing -> v -- TODO handle this case

    lpTN = take halfL lpOT
    (uiN, halfL) = if ui > lenT
      then (,) ui (lenT + (ceiling $ (fromIntegral (ui - lenT)) / 2))
      else (,) lenOT lenOT

    lenT = length lpT
    lenOT = length lpOT -- Full para / orig length

    lpOT = maybe [] identity $ List.lookup lpN annText

    newPara = List.lookup (lpN + 1) annText

textAdjustF (annText, Nothing) (_, ps) = ((0,(length lpOT)),ps)
    where
      ((lpN, lpT):_) = reverse ps
      lpOT = maybe [] identity $ List.lookup lpN annText

-- lower bound is towards end, upper bound is towards start
-- Do binary search between these bounds
textAdjustRevF
  :: [(Int,AnnotatedPara)]
  -> Maybe TextAdjust
  -> ((Int,Int), [(Int,AnnotatedPara)])
  -> ((Int,Int), [(Int,AnnotatedPara)])

textAdjustRevF annText (Just ShrinkText) ((li,ui),(fp:ps)) = case (fp) of
  (_,[]) -> case ps of
    (fp':ps') -> textAdjustRevF annText (Just ShrinkText)
      ((0,length fp'), ps)
    [] -> error "textAdjustRevF error"

  (fpN,fpT) -> ((li, (length fpT) )
      , (fpN, nfpT) : ps)
    where halfL = if li < lenT
            then li + (floor $ (fromIntegral (lenT - li)) / 2)
            else (floor $ (fromIntegral lenT) / 2)
          nfpT = reverse $ take halfL $ reverse fpT
          lenT = length fpT

textAdjustRevF annText (Just GrowText) v@(_,[])
  = error "textAdjustRevF error empty"

textAdjustRevF annText (Just GrowText) v@((li,ui), ((fpN, fpT):ps)) =
  (\(i,n) -> (i, n ++ ps)) newFp
  where
    newFp = if lenT < lenOT
      then (,) (lenT, ui) [(fpN, fpTN)]
      -- This para content over, add a new Para
      else case newPara of
             Just np -> (,) (0, length np) $ (fpN - 1, np): [(fpN, fpT)]
             Nothing -> v -- TODO handle this case

    fpTN = reverse $ take halfL $ reverse fpOT
    halfL = lenT + (ceiling $ (fromIntegral (ui - lenT)) / 2)

    lenT = length fpT
    lenOT = length fpOT -- Full para / orig length

    fpOT = maybe [] identity $ List.lookup fpN annText

    newPara = List.lookup (fpN - 1) annText

textAdjustRevF _ Nothing v = v

renderDynParas :: (_)
  => Dynamic t (ReaderSettings CurrentDb) -- Used for mark
  -> Dynamic t [(Int,AnnotatedPara)]
  -> m (Event t ([VocabId], (Text, Maybe e)))
renderDynParas rs dynParas = do
  let dynMap = Map.fromList <$> dynParas
      renderF vIdDyn = renderOnePara vIdDyn (_rubySize <$> rs)
      renderEachPara vIdDyn dt = do
        ev <- dyn (renderF vIdDyn<$> dt)
        switchPromptly never ev

 -- (Dynamic t (Map k ((Event t ([VocabId], Text)))))
  rec
    let
      vIdEv = switchPromptlyDyn $ (fmap (leftmost . Map.elems)) v
    v <- list dynMap (renderEachPara vIdDyn)
    vIdDyn <- holdDyn [] (fmap fst vIdEv)
  return (vIdEv)


renderVerticalBackwards :: (_)
  => _
  -> _
  -> _
  -> m (Event t (Int,Int))

renderVerticalBackwards rs divAttr (textContent, (ep,epOff)) = do
  (evVisible, action) <- newTriggerEvent
  visDyn <- holdDyn (0,Nothing) evVisible
  display visDyn

  let
    lastPara = maybe [] (take epOff) (List.lookup ep textContent)
    initState = (\t -> ((0,length t), [(ep, t)])) lastPara
    dEv = snd <$> (evVisible)
  row1Dyn <- foldDyn (textAdjustRevF textContent) initState dEv

  let
    firstDisplayedPara = (\v -> maybe (0,0) (\(pn,pt) -> (pn, length pt))
                            (preview (_2 . _head) v)) <$> row1Dyn

  text "First para num and length: "
  display firstDisplayedPara

  (rowRoot, (inside, outside)) <- elDynAttr' "div" divAttr $ do
    el "div" $ do
      renderDynParas rs (snd <$> row1Dyn)

    (inside, _) <- elAttr' "div" ("style" =: "height: 1em; width: 1em;") $ do
      text ""
    elAttr "div" ("style" =: "height: 2em; width: 3em;") $ do
      text ""
    (outside, _) <- elAttr' "div" ("style" =: "height: 1em; width: 1em;") $ do
      text ""
      return ()
    return (inside, outside)

  let inEl = _element_raw inside
      outEl = _element_raw outside

  time <- liftIO $ getCurrentTime

  let
    -- TODO Stop if we hit end of text
      stopTicks = fmapMaybe (\(_,a) -> if isNothing a then Just () else Nothing) evVisible
      startTicksAgain = updated rs -- resizeEv
      ticksWidget = do
        let init = widgetHold (tickLossy 1 time)
              (return never <$ stopTicks)
        t <- widgetHold init
          (init <$ startTicksAgain)
        return (switchPromptlyDyn $ join t)

  tickEv <- ticksWidget

  performEvent (checkVerticalOverflow (inEl, outEl)
                (_element_raw rowRoot) action <$ tickEv)

  let
    getFPOffset ((fpN, fpT):_) = (fpN, lenOT - (length fpT))
      where
        lenOT = length fpOT -- Full para / orig length
        fpOT = maybe [] identity $ List.lookup fpN textContent
  return $ getFPOffset . snd <$> tagDyn row1Dyn stopTicks

----------------------------------------------------------------------------------
lineHeightOptions = Map.fromList $ (\x -> (x, (tshow x) <> "%"))
  <$> ([100,150..400]  :: [Int])

fontSizeOptions = Map.fromList $ (\x -> (x, (tshow x) <> "%"))
  <$> ([80,85..200]  :: [Int])

writingModeOptions = Map.fromList $
  [(False, "Horizontal" :: Text)
  , (True, "Vertical")]

numOfLinesOptions = Map.fromList $ (\x -> (x, (tshow x) <> "px"))
  <$> ([100,150..2000]  :: [Int])

