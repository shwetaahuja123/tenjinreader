{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecursiveDo #-}
module SrsWidget where

import FrontendCommon
import SpeechRecog
import ReviewState

import qualified Data.Text as T
import qualified Data.Set as Set
import qualified Data.Map as Map
import qualified Data.List.NonEmpty as NE
import Data.List.NonEmpty (NonEmpty)
import System.Random
import qualified GHCJS.DOM.HTMLElement as DOM

#if defined (ghcjs_HOST_OS)
import Language.Javascript.JSaddle.Object
import Language.Javascript.JSaddle.Types
#endif

data SrsWidgetView =
  ShowStatsWindow | ShowReviewWindow ReviewType | ShowBrowseSrsItemsWindow
  deriving (Eq)

srsWidget
  :: AppMonad t m
  => AppMonadT t m ()
srsWidget = divClass "" $ do
  ev <- getPostBuild

  let widgetReDraw w redraw = do
        evDyn <- widgetHold (w)
          (w <$ redraw)
        return $ switch (current evDyn)
  rec
    let
      visEv = leftmost [ev1,ev2,ev3,ev4, ShowStatsWindow <$ ev]
      refreshEv = (() <$ visEv)
    vis <- holdDyn ShowStatsWindow visEv

    ev1 <- handleVisibility ShowStatsWindow vis $
      showStats refreshEv

    (ev2, editDone) <- handleVisibility ShowBrowseSrsItemsWindow vis $
      browseSrsItemsWidget

    ev3 <- handleVisibility (ShowReviewWindow ReviewTypeRecogReview) vis $
      widgetReDraw (reviewWidget (Proxy :: Proxy RecogReview) refreshEv) editDone

    ev4 <- handleVisibility (ShowReviewWindow ReviewTypeProdReview) vis $
      widgetReDraw (reviewWidget (Proxy :: Proxy ProdReview) refreshEv) editDone
  return ()

showStats
  :: AppMonad t m
  => Event t ()
  -> AppMonadT t m (Event t SrsWidgetView)
showStats refreshEv = do
  s <- getWebSocketResponse (GetSrsStats () <$ refreshEv)
  showWSProcessing refreshEv s
  retEvDyn <- widgetHold (return never) (showStatsWidget <$> s)
  return $ switch (current retEvDyn)

showStatsWidget
  :: (MonadWidget t m)
  => (SrsStats, SrsStats) -> m (Event t SrsWidgetView)
showStatsWidget (recog, prod) = do
  let
    w lbl rs = divClass "panel panel-default" $ do
      ev <- divClass "panel-heading" $ divClass "row" $ do
        elClass "h4" "col-sm-3" $ text lbl
        divClass "col-sm-4" $
          btn "btn-lg btn-success" "Start Review"

      divClass "panel-body" $ divClass "row" $ do
        divClass "col-sm-1" $ text "Pending:"
        divClass "col-sm-2" $ text $ tshow (reviewsToday rs)
        divClass "col-sm-1" $ text "Total Reviews:"
        divClass "col-sm-2" $ text $ tshow (totalReviews rs)
        divClass "col-sm-1" $ text "Average Success"
        divClass "col-sm-2" $ text $ tshow (averageSuccess rs) <> "%"

      return ev

  ev1 <- w "Recognition Review" recog
  ev2 <- w "Production Review" prod
  browseEv <- btn "btn-primary" "Browse Srs Items"
  return $ leftmost
    [ShowReviewWindow ReviewTypeRecogReview <$ ev1
    , ShowReviewWindow ReviewTypeProdReview <$ ev2
    , ShowBrowseSrsItemsWindow <$ browseEv]

srsLevels = Map.fromList
  [ (LearningLvl, "Less than 4 Days" :: Text)
  , (IntermediateLvl , "Between 4 to 60 Days")
  , (MatureLvl, "More than 60 Days")]

data BrowseSrsItemsOptions
  = BrowseSrsItemsDue
  | BrowseSrsItemsNew
  | BrowseSrsItemsSusp
  | BrowseSrsItemsOther
  deriving (Eq, Ord, Show)

browseOptions = Map.fromList
  [ (BrowseSrsItemsDue, "Due" :: Text)
  ,  (BrowseSrsItemsNew, "New")
  ,  (BrowseSrsItemsSusp, "Suspended")
  ,  (BrowseSrsItemsOther, "Others")]

revTypeSel = Map.fromList
  [ (ReviewTypeRecogReview, "Recognition" :: Text)
  , (ReviewTypeProdReview, "Production")]

getBrowseSrsItemsEv ::
     (MonadFix m, MonadHold t m, Reflex t)
  => Dropdown t BrowseSrsItemsOptions
  -> Dropdown t SrsItemLevel
  -> m (Dynamic t BrowseSrsItemsFilter)
getBrowseSrsItemsEv filt levels = do
  let f (This BrowseSrsItemsNew) _ = BrowseNewItems
      f (This b) BrowseNewItems = g b LearningLvl
      f (This b) (BrowseDueItems l)   = g b l
      f (This b) (BrowseSuspItems l)  = g b l
      f (This b) (BrowseOtherItems l) = g b l

      f (That _) BrowseNewItems = BrowseNewItems
      f (That l) (BrowseDueItems _) = BrowseDueItems l
      f (That l) (BrowseSuspItems _) = BrowseSuspItems l
      f (That l) (BrowseOtherItems _) = BrowseOtherItems l

      f (These b l) _ = g b l

      g BrowseSrsItemsDue l = BrowseDueItems l
      g BrowseSrsItemsNew _ = BrowseNewItems
      g BrowseSrsItemsSusp l = BrowseSuspItems l
      g BrowseSrsItemsOther l = BrowseOtherItems l

  foldDyn f (BrowseDueItems LearningLvl)
    (align (filt ^. dropdown_change) (levels ^. dropdown_change))
-- Fetch all srs items then apply the filter client side
-- fetch srs items for every change in filter
--
browseSrsItemsWidget
  :: forall t m . AppMonad t m
  => AppMonadT t m (Event t SrsWidgetView, Event t ())
browseSrsItemsWidget = do
  -- Widget declarations
  let
    ddConf :: _
    ddConf = def & dropdownConfig_attributes .~ (constDyn ddAttr)
    ddAttr = ("class" =: "form-control input-sm")

    filterOptionsWidget =
      divClass "panel-heading" $ divClass "form-inline" $ divClass "form-group" $ do
        -- Selection buttons
        selectAllToggleCheckBox <- divClass "col-sm-1" $ do

          checkbox False def -- & setValue .~ allSelected

        filt <- dropdown (BrowseSrsItemsDue) (constDyn browseOptions) ddConf
        levels <- dropdown (LearningLvl) (constDyn srsLevels) ddConf
        revType <- dropdown (ReviewTypeRecogReview) (constDyn revTypeSel) ddConf

        brwDyn <- getBrowseSrsItemsEv filt levels
        let filtOptsDyn = BrowseSrsItems <$> value revType <*> brwDyn
        return (filtOptsDyn, selectAllToggleCheckBox, value filt, value revType)

    checkBoxList selAllEv es =
      divClass "" $ do
        -- el "label" $ text "Select Items to do bulk edit"
        dyns <- elAttr "div" (("class" =: "")
                <> ("style" =: "height: 400px; overflow-y: auto")) $
          elClass "table" "table table-striped" $ el "tbody" $
            forM es $ checkBoxListEl selAllEv

        let f (v, True) = Just v
            f (_, False) = Nothing
            ds = distributeListOverDynPure dyns

        return $ (catMaybes . (map f)) <$> ds

    checkBoxListEl :: Event t Bool -> SrsItem
      -> AppMonadT t m (Dynamic t (SrsEntryId , Bool))
    checkBoxListEl selAllEv (SrsItem i t) = el "tr" $ do
      c1 <- elClass "td" "col-sm-1" $
        checkbox False $ def & setValue .~ selAllEv
      elClass "td" "el-sm-4" $
        text $ fold $ NE.intersperse ", " $ t
      ev <- elClass "td" "el-sm-2" $
        btn "btn-sm btn-primary" "edit"
      _ <- openEditSrsItemWidget $ i <$ ev
      return $ (,) i <$> (value c1)

  -- UI
  (closeEv, editDone) <- divClass "panel panel-default" $ do
    (e,_) <- elClass' "button" "close" $ text "Close"

    -- Filter Options
    (browseSrsFilterDyn, selectAllToggleCheckBox, filtOptsDyn, revTypeDyn) <-
      filterOptionsWidget

    evPB <- getPostBuild
    rec
      let
        checkBoxSelAllEv = updated $
          value selectAllToggleCheckBox

        reqEv = leftmost
          [ updated browseSrsFilterDyn
          , tag (current browseSrsFilterDyn) editDone
          , tag (current browseSrsFilterDyn) evPB]
      itemEv <- getWebSocketResponse reqEv

      -- List and selection checkBox
      selList <- divClass "panel-body" $ do
        showWSProcessing reqEv itemEv
        widgetHold (checkBoxList never [])
          (checkBoxList checkBoxSelAllEv <$> itemEv)
      -- Action buttons
      editDone <-
        bulkEditWidgetActionButtons filtOptsDyn revTypeDyn $ join selList
    return (domEvent Click e, editDone)

  return $ (ShowStatsWindow <$ closeEv, editDone)

btnWithDisable :: (_)
  => Text
  -> Dynamic t1 Bool
  -> m (Event t ())
btnWithDisable t active = do
  let attr True = ("type" =: "button") <> ("class" =: "btn btn-primary active")
      attr False = ("type" =: "button") <> ("class" =: "btn btn-primary disabled")
  (e, _) <- elDynAttr' "button" (attr <$> active) $ text t
  return $ domEvent Click e

bulkEditWidgetActionButtons
  :: AppMonad t m
  => Dynamic t BrowseSrsItemsOptions
  -> Dynamic t ReviewType
  -> Dynamic t [SrsEntryId]
  -> AppMonadT t m (Event t ())
bulkEditWidgetActionButtons filtOptsDyn revTypeDyn selList = divClass "panel-footer" $ do
  today <- liftIO $ utctDay <$> getCurrentTime

  let
      felem = flip elem

  el "table" $ el "tbody" $ do
    suspendEv <-
      el "td" $
      btnWithDisable "Suspend" $ (felem [BrowseSrsItemsDue, BrowseSrsItemsOther]) <$> filtOptsDyn

    markDueEv <- el "td" $
      btnWithDisable "Mark Due" $ (felem [BrowseSrsItemsSusp, BrowseSrsItemsOther]) <$> filtOptsDyn

    deleteEv <- el "td" $
      btnWithDisable "Delete" (constDyn True)

    reviewDateChange <- el "td" $
      btnWithDisable "Change Review Date" $ (felem [BrowseSrsItemsDue,
         BrowseSrsItemsSusp, BrowseSrsItemsOther]) <$> filtOptsDyn

    dateDyn <- el "td" $ datePicker today
    let bEditOp = leftmost
          [DeleteSrsItems <$ deleteEv
          , MarkDueSrsItems <$ markDueEv
          , SuspendSrsItems <$ suspendEv
          , ChangeSrsReviewData <$> tag (current dateDyn) reviewDateChange]
    doUpdate <- getWebSocketResponse $
      (attachWith ($) (current $ BulkEditSrsItems <$> revTypeDyn <*> selList) bEditOp)
    showWSProcessing bEditOp doUpdate
    return $ fmapMaybe identity doUpdate

datePicker
  :: (MonadWidget t m)
  => Day -> m (Dynamic t Day)
datePicker today = divClass "" $ do
  let dayList = makeList [1..31]
      monthList = makeList [1..12]
      yearList = makeList [2000..2030]
      makeList x1 = constDyn $ Map.fromList $ (\x -> (x, tshow x)) <$> x1
      (currentYear, currentMonth, currentDay)
        = toGregorian today
      mycol = divClass ""
        --elAttr "div" (("class" =: "column") <> ("style" =: "min-width: 2em;"))
  day <- mycol $ dropdown currentDay dayList $ def
  month <- mycol $ dropdown currentMonth monthList $ def
  year <- mycol $ dropdown currentYear yearList $ def
  return $ fromGregorian <$> value year <*> value month <*> value day

reviewDataPicker :: (MonadWidget t m) =>
  Maybe Day -> m (Dynamic t (Maybe Day))
reviewDataPicker inp = do
  today <- liftIO $ utctDay <$> getCurrentTime

  let
    addDateW = do
      button "Add Next Review Date"

    selectDateW = do
      divClass "" $ do
        newDateDyn <- divClass "" $ datePicker defDate
        removeDate <- divClass "" $
          button "Remove Review Date"
        return (removeDate, newDateDyn)

    defDate = maybe today identity inp

  rec
    vDyn <- holdDyn (isJust inp) (leftmost [False <$ r, True <$ a])
    a <- handleVisibility False vDyn addDateW
    (r,d) <- handleVisibility True vDyn selectDateW
  let
      f :: Reflex t => (Dynamic t a) -> Bool -> Dynamic t (Maybe a)
      f a True = Just <$> a
      f _ _ = pure Nothing
  return $ join $ f d <$> vDyn

reviewWidget
  :: forall t m rt proxy . (AppMonad t m, SrsReviewType rt)
  => proxy rt
  -> Event t ()
  -> AppMonadT t m (Event t SrsWidgetView)
reviewWidget p refreshEv = do
  initWanakaBindFn
  let
    rt = reviewType p

  -- ev <- getPostBuild
  -- initEv <- getWebSocketResponse $ GetNextReviewItems rt [] <$ ev

  rec
    -- Input Events
    -- 1. Initial review items
    -- 2. Review result
    -- 3. Fetch new items from server
    -- 4. Undo event
    -- 5. refresh (if initEv was Nothing)

    let
    -- Output Events
    -- 1. Show review item
    -- 2. Fetch new reviews
    -- 3. Send the result back
    widgetStateDyn <- foldDyn (flip (foldl widgetStateFun))
      (SrsWidgetState Map.empty Map.empty Nothing def)
      (mergeList [addItemEv, reviewResultEv])

    let
      addResEv = fmapMaybe (_resultQueue)
          (updated widgetStateDyn)

      newReviewEv = leftmost [() <$ reviewResultEv
                             ,() <$ refreshEv]

    (addItemEv :: Event t (ReviewStateEvent rt))
      <- syncResultWithServer rt refreshEv
        addResEv widgetStateDyn

    (closeEv, reviewResultEv) <- reviewWidgetView
      (_reviewStats <$> widgetStateDyn)
      =<< getRevItemDyn widgetStateDyn newReviewEv

  return $ ShowStatsWindow <$ closeEv

-- Start initEv (show review if available)
-- review done ev, fetch new event after update of dyn
getRevItemDyn
  :: (MonadFix m,
       MonadHold t m,
       SrsReviewType rt,
       MonadIO (Performable m),
       PerformEvent t m)
  => Dynamic t (SrsWidgetState rt)
  -> Event t ()
  -> m (Dynamic t (Maybe (ReviewItem, ActualReviewType rt)))
getRevItemDyn widgetStateDyn ev = do
  rec
    v <- performEvent $ ffor (tagPromptlyDyn ((,) <$> riDyn <*> widgetStateDyn) ev) $
      \(last, st) -> do
        t <- liftIO $ getCurrentTime
        let
          allrs = (Map.toList (_reviewQueue st))
          rs | length allrs > 1 = maybe allrs
               (\(l,_) -> filter (\r -> (_reviewItemId l) /= (fst r)) allrs) last
             | otherwise = allrs

        let
          loop = do
            rss <- liftIO $ getRandomItems rs 1
            let
              riMb = headMay rss
            case (join $ (\(i,_) -> Map.lookup i (_incorrectItems st)) <$> riMb) of
              Nothing -> return riMb
              (Just t1) -> if (diffUTCTime t t1 > 60)
                then return riMb
                else if (length allrs > 1) && (length rs > (Map.size (_incorrectItems st)))
                       then loop
                       else return riMb

        rIdMb <- loop
        toss <- liftIO $ randomIO
        return $ (\(_,(ri,rt)) -> (ri, getRandomRT ri rt toss)) <$> rIdMb

    riDyn <- holdDyn Nothing v
  return riDyn


getRandomItems :: [a] -> Int -> IO [a]
getRandomItems inp s = do
  let l = length inp
      idMap = Map.fromList $ zip [1..l] inp

      loop set = do
        r <- randomRIO (1,l)
        let setN = Set.insert r set
        if Set.size setN >= s
          then return setN
          else loop setN

  set <- loop Set.empty
  return $ catMaybes $
    fmap (\k -> Map.lookup k idMap) $ Set.toList set

-- Required inputs for working of review widget
-- 1. Field (What to display to user as question)
-- 2. Field Tags (?)
-- 3. Answer
-- 4. Additional notes (Shown after answering question)
reviewWidgetView
  :: (AppMonad t m, SrsReviewType rt)
  => Dynamic t SrsReviewStats
  -> Dynamic t (Maybe (ReviewItem, ActualReviewType rt))
  -> AppMonadT t m (Event t (), Event t (ReviewStateEvent rt))
reviewWidgetView statsDyn dyn2 = divClass "panel panel-default" $ do
  let
    statsTextAttr = ("style" =: "font-size: large;")
      <> ("class" =: "center-block text-center")

    showStatsW = do
      let colour c = ("style" =: ("color: " <> c <>";" ))
          labelText t = elClass "span" "small text-muted" $ text t
      labelText "Pending "
      el "span" $
        dynText $ (tshow . _srsReviewStats_pendingCount) <$> statsDyn
      text "\t|\t"
      labelText " Correct "
      elAttr "span" (colour "green") $
        dynText $ (tshow . _srsReviewStats_correctCount) <$> statsDyn
      text "\t|\t"
      labelText " Incorrect "
      elAttr "span" (colour "red") $
        dynText $ (tshow . _srsReviewStats_incorrectCount) <$> statsDyn

  (fullASR, closeEv) <- divClass "panel-heading" $ do
    (e,_) <- elClass' "button" "close" $ text "Close"

    let cEv = domEvent Click e
#if defined (ENABLE_SPEECH_RECOG)
    fullASR <- do
      cb <- checkbox False $ def & checkboxConfig_setValue .~ (False <$ cEv)
      text "Auto ASR"
      return (value cb)
#else
    let fullASR = constDyn False
#endif

    divClass "" $ do
      elAttr "span" statsTextAttr $
        showStatsW
    return $ (fullASR, cEv)

  let kanjiRowAttr = ("class" =: "center-block")
         <> ("style" =: "height: 15em; display: table;")
      kanjiCellAttr = ("style" =: "vertical-align: middle; max-width: 25em; display: table-cell;")

  _ <- elAttr "div" kanjiRowAttr $ elAttr "div" kanjiCellAttr $ do
    let
      showNE (Just (ne, stl)) = elAttr "span" kanjiTextAttr $ do
          mapM_ text (NE.intersperse ", " ne)
        where kanjiTextAttr = ("style" =: stl)
      showNE Nothing = text "No Reviews! (Please close and open again to refresh)"
    dyn $ showNE <$> (dyn2 & mapped . mapped %~ (uncurry getField))

  doRecog <- lift $ speechRecogSetup

  dr <- dyn $ ffor dyn2 $ \case
    (Nothing) -> return never
    (Just v) -> inputFieldWidget doRecog closeEv fullASR v

  evReview <- switchPromptly never dr
  return (closeEv, evReview)
    --leftmost [evB, dr, drSpeech]

inputFieldWidget
  :: (AppMonad t m, SrsReviewType rt)
  => (Event t () -> Event t () -> m (Event t Result, Event t (), Event t (), Event t ()))
  -> Event t ()
  -> Dynamic t Bool
  -> (ReviewItem, ActualReviewType rt)
  -> AppMonadT t m (Event t (ReviewStateEvent rt))
inputFieldWidget doRecog closeEv fullASR (ri@(ReviewItem i k m _), rt) = do
  let
    tiId = getInputFieldId rt
    style = "text-align: center; width: 100%;" <> color
    color = getInputFieldStyle rt
    ph = getInputFieldPlaceHolder rt
    inputField = do
      let tiAttr = def
            & textInputConfig_attributes
            .~ constDyn (("style" =: style)
                        <> ("id" =: tiId)
                        <> ("class" =: "form-control")
                        <> ("placeholder" =: ph)
                        <> ("autocapitalize" =: "none")
                        <> ("autocorrect" =: "none")
                        <> ("autocomplete" =: "off"))
      divClass "" $
        divClass "" $ do
          textInput tiAttr

    showResult b = divClass "" $ do
      let s = if b then "Correct: " else "Incorrect: "
          ans = getAnswer ri rt
      text $ s <> (fold $ case ans of
        (Left m) -> NE.intersperse ", " $ fmap unMeaning m
        (Right r) -> NE.intersperse ", " $ (fmap unReading r) <> (ri ^. reviewItemField))
      divClass "" $ do
        text "Notes:"
        case ans of
          (Left _) -> forMOf_ (reviewItemMeaning . _2 . _Just . to unMeaningNotes) ri
            $ \mn -> text $ "> " <> mn
          (Right _) -> forMOf_ (reviewItemReading . _2 . _Just . to unReadingNotes) ri
            $ \mn -> text $ "> " <> mn

  inpField <- inputField
  (dr, resEv) <-
    reviewInputFieldHandler inpField rt ri

  -- Need dalay, otherwise focus doesn't work
  evPB <- delay 0.1 =<< getPostBuild

  let focusAndBind e = do
        DOM.focus e
        let ans = getAnswer ri rt
        when (isRight ans) bindWanaKana

  _ <- widgetHold (return ()) (focusAndBind (_textInput_element inpField) <$ evPB)

  let resultDisAttr = ("class" =: "")
          <> ("style" =: "height: 6em; overflow-y: auto")
  rec
    _ <- elAttr "div" resultDisAttr $
      widgetHold (return ()) (showResult <$> (leftmost [resEv, shimesuEv, recogCorrectEv]))

    -- Footer
    (shiruResEv, addEditEv, (recogCorrectEv, recogResEv)
      , shimesuEv, recogStop, susBuryEv) <- divClass "row" $ do
#if defined (ENABLE_SPEECH_RECOG)
      recog <- divClass "col-sm-2" $
        speechRecogWidget doRecog recogStop fullASR (ri, rt)
#else
      let recog = (never,never)
#endif

      shirimasu <- divClass "col-sm-2" $
        btn "btn-primary" "知っている"

      (shimesu, shiranai) <- divClass "col-sm-2" $ do
        rec
          let evChange = (leftmost [ev, () <$ fst recog])
          ev <- switch . current <$> widgetHold (btn "btn-primary" "示す")
            (return never <$ evChange)
        ev2 <- widgetHoldWithRemoveAfterEvent ((btn "btn-primary" "知らない") <$ evChange)
        return (ev,ev2)

      recogStop1 <- divClass "col-sm-2" $ do
        openEv <- btn "btn-primary" "Sentences"
        openSentenceWidget (NE.head k, map (unMeaning) $ NE.toList (fst m)) (Right i <$ openEv)
        return openEv

      (recogStop2, aeEv) <- divClass "col-sm-2" $ do
        ev <- btn "btn-primary" "Show/Edit details"
        newSrsEntryEv <- openEditSrsItemWidget (i <$ ev)
        return $ (,) ev ((\s -> AddItemsEv [getReviewItem s] Nothing) <$> newSrsEntryEv)

      sbEv <- divClass "col-sm-2" $ do
        ev1 <- btn "btn-primary" "Bury"
        ev2 <- btn "btn-primary" "Suspend"
        return (leftmost [SuspendEv i <$ ev2, BuryEv i <$ ev1])

      shiruRes <- tagWithTime $ (\b -> (i, rt, b)) <$>
        leftmost [True <$ shirimasu, False <$ shiranai]

      return (shiruRes , aeEv, recog, False <$ shimesu
             , leftmost [recogStop2, recogStop1, shirimasu, closeEv]
             , sbEv)

  return $ leftmost [ shiruResEv , recogResEv
                    , dr, addEditEv, susBuryEv]

tagWithTime ev = performEvent $ ffor ev $ \e@(i,_,b) -> do
  t <- liftIO $ getCurrentTime
  return $ DoReviewEv e t

reviewInputFieldHandler
 :: (MonadFix m,
     MonadHold t m,
     PerformEvent t m,
     MonadIO (Performable m),
     Reflex t,
     SrsReviewType rt)
 => TextInput t
 -> ActualReviewType rt
 -> ReviewItem
 -> m (Event t (ReviewStateEvent rt), Event t Bool)
reviewInputFieldHandler ti rt ri@(ReviewItem i _ _ _) = do
  let enterPress = ffilter (==13) (ti ^. textInput_keypress) -- 13 -> Enter
      correct = current $ checkAnswer n <$> value ti
      n = getAnswer ri rt
      h _ ReviewStart = ShowAnswer
      h _ ShowAnswer = NextReview
      h _ _ = ReviewStart
  d <- foldDyn h ReviewStart enterPress
  let

  -- the dr event will fire after the correctEv (on second enter press)
    correctEv = tag correct enterPress
    sendResult = ffilter (== NextReview) (tag (current d) enterPress)
  dr <- tagWithTime $ (\b -> (i, rt, b)) <$> tag correct sendResult
  return (dr, correctEv)

-- TODO For meaning reviews allow minor mistakes
checkAnswer :: (Either (NonEmpty Meaning) (NonEmpty Reading))
            -> Text
            -> Bool
checkAnswer (Left m) t = elem (T.toCaseFold $ T.strip t) (answers <> woExpl <> woDots)
  where answers = map (T.toCaseFold . unMeaning) m
        -- as (i.e. in the role of) -> as
        woExpl = map (T.strip . fst . (T.breakOn "(")) answers
        -- apart from... -> apart from
        woDots = map (T.strip . fst . (T.breakOn "...")) answers

checkAnswer (Right r) t = elem t answers
  where answers = map unReading r

checkSpeechRecogResult
  :: (AppMonad t m, SrsReviewType rt)
  => (ReviewItem, ActualReviewType rt)
  -> Event t Result
  -> AppMonadT t m (Event t Bool)
checkSpeechRecogResult (ri,rt) resEv = do
  let
    checkF res = do
      ev <- getPostBuild
      let
        r1 = any ((\r -> elem r (NE.toList $ ri ^. reviewItemField))
                  . snd) (concat res)
        r2 = any ((checkAnswer n) . snd) (concat res)
        n = getAnswer ri rt
        readings = case n of
          (Left _) -> []
          (Right r) -> NE.toList r
      if r1 || r2
        then return (True <$ ev)
        else do
          respEv <- getWebSocketResponse $ CheckAnswer readings res <$ ev
          return ((== AnswerCorrect) <$> respEv)

  evDyn <- widgetHold (return never)
    (checkF <$> resEv)
  return $ switch . current $ evDyn


data AnswerBoxState = ReviewStart | ShowAnswer | NextReview
  deriving (Eq)

-- Ord is used in getStChangeEv
data SpeechRecogWidgetState
  = AnswerSuccessful
  | AnswerWrong
  | WaitingForServerResponse
  | WaitingForRecogResponse
  | SpeechRecogStarted
  | RecogStop
  | RecogError
  | NewReviewStart
  deriving (Eq, Ord, Show)

btnText :: SpeechRecogWidgetState
  -> Text
btnText NewReviewStart = "Recog Paused"
btnText SpeechRecogStarted = "Ready"
btnText WaitingForRecogResponse = "Listening"
btnText WaitingForServerResponse = "Processing"
btnText AnswerSuccessful = "Correct!"
btnText AnswerWrong = "Not Correct, Please try again"
btnText RecogError = "Error, Please try again"
btnText RecogStop = "Please try again"


--
speechRecogWidget :: forall t m rt . (AppMonad t m, SrsReviewType rt)
  => (Event t () -> Event t () -> m (Event t Result, Event t (), Event t (), Event t ()))
  -> Event t ()
  -> Dynamic t Bool
  -> (ReviewItem, ActualReviewType rt)
  -> AppMonadT t m (Event t Bool, Event t (ReviewStateEvent rt))
speechRecogWidget doRecog stopRecogEv fullASR (ri@(ReviewItem i _ _ _),rt) = do

  initVal <- sample (current fullASR)
  rec
    fullAsrActive <- holdDyn initVal (leftmost [(False <$ stopRecogEv)
                                   , updated fullASR
                                   , True <$ reStartRecogEv])
    reStartRecogEv <- switchPromptly never
      =<< (dyn $ ffor ((,) <$> fullAsrActive <*> fullASR) $ \case
        (False, True) ->  btn "btn-primary" "Resume Recog"
        _ -> return never)

  initEv <- switchPromptly never
    =<< (dyn $ ffor fullASR $ \b -> if b
      then delay 0.5 =<< getPostBuild
      else btn "btn-sm btn-primary" "Start Recog")

  rec
    let
      startRecogEv = leftmost [initEv, () <$ resultWrongEv
                              , () <$ shimesuEv, () <$ retryEv
                              , reStartRecogEv
                              -- , () <$ filterOnEq (updated fullASR) True
                              ]
      (shimesuEv, shiruEv, tsugiEv, answerEv) =
        checkForCommand $
          traceEventWith (T.unpack . mconcat . (intersperse ", ") .
                          (fmap snd) . concat) $
          resultEv

    (resultCorrectEv, resultWrongEv) <- do
      bEv <- checkSpeechRecogResult (ri,rt) answerEv
      return $ (True <$ filterOnEq bEv True, filterOnEq bEv False)


    (resultEv, recogStartEv, recogEndEv, stopEv) <- lift $ doRecog stopRecogEv startRecogEv

    retryEv <- switchPromptly never =<< (dyn $ ffor fullAsrActive $ \b -> if not b
      then return never
      else do
        -- This delay is required to avoid repetitive restarts
        recogEndEvs <- batchOccurrences 4 $
          mergeList [ WaitingForServerResponse <$ resultEv
                   , AnswerSuccessful <$ resultCorrectEv
                   , AnswerWrong <$ resultWrongEv
                   , RecogError <$ stopEv
                   , RecogStop <$ recogEndEv
                   ]
        let recogChangeEv = getStChangeEv recogEndEvs
        return $ leftmost [(filterOnEq recogChangeEv RecogStop)
                          , filterOnEq recogChangeEv RecogError])

    -- btnClick <- (dyn $ (\(c,t) -> btn c t) <$> (btnText <$> stDyn))
    --         >>= switchPromptly never

  allEvs <- batchOccurrences 2 $
    mergeList [SpeechRecogStarted <$ startRecogEv
             , WaitingForRecogResponse <$ recogStartEv
             , WaitingForServerResponse <$ resultEv
             , AnswerSuccessful <$ resultCorrectEv
             , AnswerWrong <$ resultWrongEv
             , RecogError <$ stopEv
             , RecogStop <$ recogEndEv]

  do
    let stChangeEv = getStChangeEv allEvs
    stDyn <- holdDyn NewReviewStart stChangeEv
    el "h4" $ elClass "span" "label label-primary" $ dynText (btnText <$> stDyn)

  let
    -- shimesuEv -> Mark incorrect
    -- shiruEv -> Mark correct

    answerCorrectEv = leftmost [True <$ shiruEv, resultCorrectEv]


  autoNextEv <- switchPromptly never =<< (dyn $ ffor fullAsrActive $ \b -> if b
    then delay 3 (() <$ answerCorrectEv)
    else return never)

  answeredCorrect <- holdDyn False answerCorrectEv

  let
    btnClickDoReview = never -- TODO
    showResEv  = leftmost [answerCorrectEv, False <$ shimesuEv]
  doReviewEv <- tagWithTime $ (\r -> (i,rt,r)) <$> (tag (current answeredCorrect)
      $ leftmost [btnClickDoReview, autoNextEv, tsugiEv])

  return (showResEv, doReviewEv)

checkForCommand
  :: (Reflex t)
  => Event t Result
  -> (Event t ()
     , Event t ()
     , Event t ()
     , Event t Result)
checkForCommand r = (shimesuEv, shiruEv, tsugiEv, answerEv)
  where
    shimesuEv = leftmost [fmapMaybe identity (f shimesuOpts)
                       , fmapMaybe identity (f shiranaiOpts)]
    shiruEv = fmapMaybe identity (f shiruOpts)
    tsugiEv = fmapMaybe identity (f tsugiOpts)
    answerEv = difference r (leftmost [shimesuEv, shiruEv, tsugiEv])

    f opts = ffor r $ \res ->
      if (any ((\x -> elem x opts) . snd) (concat res))
        then Just ()
        else Nothing

    shiruOpts = ["わかる", "分かる", "わかります", "分かります"
                 , "知る", "しる", "しります", "知ります"
      , "知っています", "知っている", "知ってる"
      , "しっています", "しっている", "しってる"]
    shiranaiOpts =
      ["わからない", "分からない", "わかりません", "分かりません"
      , "知らない", "しらない", "しりません", "知りません"]
    shimesuOpts = ["しめす", "しめします", "示す", "示します"]
    tsugiOpts = ["つぎ", "次", "Next", "NEXT", "ネクスト"]

getStChangeEv
  :: (Reflex t)
  => Event t (Seq (NonEmpty SpeechRecogWidgetState))
  -> Event t SpeechRecogWidgetState
getStChangeEv = fmap (\s -> minimum $ fold $ map NE.toList s)

initWanakaBindFn :: (MonadWidget t m) => m ()
initWanakaBindFn =
#if defined (ghcjs_HOST_OS)
  void $ liftJSM $ eval ("globalFunc_wanakanaBind = function () {"
                <> "var input1 = document.getElementById('JP-TextInput-IME-Input1');"
                <> "var input2 = document.getElementById('JP-TextInput-IME-Input2');"
                <> "wanakana.bind(input1); wanakana.bind(input2);}" :: Text)
#else
  return ()
#endif

bindWanaKana :: (MonadWidget t m) => m ()
bindWanaKana =
#if defined (ghcjs_HOST_OS)
        void $ liftJSM $
          jsg0 ("globalFunc_wanakanaBind" :: Text)
#else
  return ()
#endif
