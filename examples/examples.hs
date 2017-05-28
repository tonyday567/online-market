{-# OPTIONS_GHC -Wall #-}

import Online

import Chart
import Data.Binary
import Data.List
import Data.Quandl
import Data.Reflection
import Formatting
import Numeric.AD
import Numeric.AD.Internal.Reverse
import Options.Generic

import NumHask.Prelude hiding ((%))
import qualified Control.Foldl as L
import Control.Lens (element)
import qualified Data.Attoparsec.Text as A
import qualified Data.ListLike as List
import qualified Protolude as P
import Data.Default()

data Opts = Download | Run (Maybe RunConfig)
   deriving (Generic, Show)

data RunConfig = RunConfig { grain :: Maybe Int } deriving (Generic, Show, Read)

instance Default RunConfig where
    def = RunConfig Nothing

instance ParseRecord RunConfig

instance ParseFields RunConfig

instance ParseField RunConfig

instance ParseRecord Opts

main :: IO ()
main = do
   o :: Opts <- getRecord "online-dev examples"
   case o of
     Download -> do
         t <- downloadData
         case t of
           (Left e) -> putStrLn $ "download failed: " <> e
           (Right xs) -> do
               putStrLn $ "data points: " <> (show $ length xs :: Text)
               encodeFile "other/data.bin" xs
     Run Nothing -> join $ run def <$> getData
     Run (Just cfg) -> join $ run cfg <$> getData

-- | get data from this site:
-- https://www.quandl.com/data/YAHOO/INDEX_GSPC-S-P-500-Index
downloadData :: IO (Either Text [Double])
downloadData = do
    t <- getTable "YAHOO" "INDEX_GSPC" Nothing
    case t of
      Nothing -> pure $ Left "No data downloaded"
      Just t1 -> case elemIndex "Close" (daColumnNames t1) of
        Nothing -> pure $ Left "No Close column"
        Just i1 ->
            let d1 = (!! i1) <$> daData t1 in
            pure $ Right $
            ( either (const nan) identity
            . A.parseOnly (A.double <* A.endOfInput))
            <$> d1

-- | compute the log return from a price series (which comes in most recent to oldest order, so needs to be reversed)
-- returns are geometric by nature, and using log(1+daily return) as the base unit of the time series leads to all sorts of benefits, not least of which is you can then add up the variates to get the cumulative return, without having to go through log and exp chicanery.  Ditto for distributional assumptions.
lret :: [Double] -> [Double]
lret [] = []
lret [_] = []
lret xs = (\x -> log (1+x)) <$> L.fold dif (reverse xs)
    where
        dif = L.Fold step ([], Nothing) fst
        step x a = case snd x of
            Nothing -> ([], Just a)
            Just a' -> ((a-a')/a':fst x, Just a)

getData :: IO [Double]
getData = either (const []) lret <$> decodeFileOrFail "other/data.bin"

run :: RunConfig -> [Double] -> IO ()
run cfg xs = do
    let gr = fromMaybe 20 (grain cfg)
    let d0 = fmap r2 <$>
            zipWith (\x y -> [(x,0.0),(x,y)]) (fromIntegral <$> [(0::Int)..]) (take 2000 xs)
    fileSvg "other/elems.svg" (600,400) $
        lineChart (repeat $ LineConfig 0.001 (Color 0.3 0.3 0.3 1)) sixbyfour d0 <>
        axes ( chartRange .~ Just (rangeR2s d0) $ chartAxes .~
               [axisPlacement .~ AxisLeft $ axisOrientation .~ Y $ def] $ def)

    fileSvg
        "other/asum.svg" (300,300)
        ( withChart def
          (lineChart [LineConfig 0.002 (Color 0.33 0.33 0.33 0.4)])
          [zipWith V2 [0..] (L.scan L.sum xs)]
        )

    let cuts = linearSpace OuterPos (Range (-0.02,0.02)) 20
    let h = toHistogramWithCuts cuts $ L.fold (onlineDigestHist 0.975) xs
    let h' = toHistogramWithCuts cuts $ L.fold tDigestHist xs
    fileSvg "other/hist-compare.svg" (300,300) $ histCompare (IncludeOvers 0.01) h h'

    fileSvg "other/cmean.svg" (300,300) $
        withChart def
        (lineChart
         [ LineConfig 0.002 (Color 0.88 0.33 0.12 1)
         , LineConfig 0.002 (Color 0.12 0.33 0.83 1)
         ])
        [ zipWith V2 [0..] $
          take 5000 $ drop 100 $ drop 2 $
          L.scan (beta 0.99) $ drop 1 $
          zip xs (L.scan (ma 0.9975) xs)
        , zipWith V2 [0..] $
          take 5000 $ drop 100 $ drop 2 $
          L.scan (alpha 0.99) $ drop 1 $
          zip xs (L.scan (ma 0.9975) xs)
        ]
        
    c1 $ withChart def
        (lineChart
         [ LineConfig 0.002 (Color 0.33 0.33 0.33 1)
         , LineConfig 0.001 (Color 0.7 0.7 0.33 1)
         ])
        [ zipWith V2 [0..] $
          drop 1 $
          L.scan (ma 0.9975) xs
        , zipWith V2 [0..] $
          drop 1 $
          L.scan (ma 0.99) xs
        ]

    c2 $ withChart def
        (lineChart
         [ LineConfig 0.002 (Color 0.33 0.33 0.33 1)
         , LineConfig 0.001 (Color 0.7 0.7 0.33 1)
         ])
        [ zipWith V2 [0..] $
          drop 1 $
          L.scan (std 0.9975) xs
        , zipWith V2 [0..] $
          drop 1 $
          L.scan (std 0.99) xs
        ]

    c3 $ withChart def
        (lineChart
         [ LineConfig 0.002 (Color 0.88 0.33 0.12 1)
         , LineConfig 0.002 (Color 0.12 0.33 0.83 1)
         ])
        [ zipWith V2 [0..] $
          drop 2 $
          L.scan (beta 0.99) $ drop 1 $
          zip xs (L.scan (ma 0.9975) xs)
        , zipWith V2 [0..] $
          drop 2 $
          L.scan (alpha 0.99) $ drop 1 $
          zip xs (L.scan (ma 0.9975) xs)
        ]

    c4 $ withChart def
        (lineChart
         [ LineConfig 0.002 (Color 0.88 0.33 0.12 1)
         ])
        [ zipWith V2 [0..] $
          drop 2 $
          L.scan ((\b o a -> a + b * o) <$>
             beta 0.99 <*>
             L.premap snd (ma 0.00001) <*>
             alpha 0.99) $
           drop 1 $ zip xs (L.scan (ma 0.9975) xs)
        ]

    fileSvg "other/c5.svg" (600,400) $
        histChart [def] sixbyfour
        [ fromHist (IncludeOvers 0.001)
        $ toHistogramWithCuts (linearSpace OuterPos (Range (-0.004,0.004)) 16)
        $ L.fold tDigestHist $ drop 2 $
          L.scan ((\b o a -> a + b * o) <$>
             beta 0.99 <*>
             L.premap snd (ma 0.00001) <*>
             alpha 0.99) $
           drop 1 $ zip xs (L.scan (ma 0.9975) xs)]

    fileSvg "other/c6.svg" (600,400) $
        scatterChart [ScatterConfig 0.0005 (Color 0.33 0.33 0.33 0.02)] sixbyfour
        [ fmap (\(x,y) -> V2 x y) $ drop 2 $
          L.scan ((\r b o a -> (r,a+b*o)) <$>
             L.premap fst (ma 0.00001) <*>
             beta 0.99 <*>
             L.premap snd (ma 0.00001) <*>
             alpha 0.99) $
           drop 1 $ zip xs (L.scan (ma 0.9975) xs)]


    let h = toHistogramWithCuts cuts $ L.fold tDigestHist $
          take 5000 $ drop 100 $
          L.scan ((\r b o a -> r - b * o - a) <$>
             L.premap fst (ma 0.00001) <*>
             beta 0.975 <*>
             L.premap snd (ma 0.00001) <*>
             alpha 0.975) $
           drop 400 $ zip xs (L.scan (ma 0.975) xs)
    let h' = toHistogramWithCuts cuts $ L.fold tDigestHist $ take 5000 $ drop 100 xs
    fileSvg "other/cmeane.svg" (300,300) $ histCompare (IncludeOvers 0.01) h h'
    fileSvg "other/csqma.svg" (300,300) $
        withChart def
        (lineChart
         [ LineConfig 0.002 (Color 0.88 0.33 0.12 1)
         , LineConfig 0.002 (Color 0.12 0.33 0.83 1)
         ])
        (fmap (zipWith V2 [0..]) <$> (\x -> [fst <$> x, snd <$> x]) $
         take 12000 $ drop 12000 $ drop 2 $
         L.scan ((,) <$> alpha 0.99 <*> beta 0.99) $
           drop 100 $ zip ((**2)<$> xs) (L.scan (sqma 0.9975) xs))

    fileSvg "other/arrows.svg" (600,600)
        (chartGrad (Rect (V2 one one)) gr 0.01 xs # pad 1.1)

{-


basic stats
---

online mean and std at a 0.99 decay rate:

-}
    let st = drop 1 $ L.scan ((,) <$> ma 0.9 <*> std 0.99) xs
    fileSvg "other/moments.svg" (300,300) (withChart def (lineChart [LineConfig 0.002 (Color 0.33 0.33 0.33 0.4), LineConfig 0.002 (Color 0.88 0.33 0.12 0.4)])
        [ zipWith V2 [0..] (fst <$> st)
        , zipWith V2 [0..] (snd <$> st)
        ])
{-
scan of 1000 recent ma 0.99 and std 0.99, in basis points, rendered as a scatter chart.

-}
    fileSvg "other/scatter.svg" (500,500) $
        withChart def (scatterChart [def]) [drop (length xs - 1000) $
        fmap (10000*) <$> L.scan (V2 <$> ma 0.99 <*> std 0.99) xs]


{-
quantiles
---

-}
    writeFile "other/quantiles.md" $
        "\n    [min, 10th, 20th, .. 90th, max]:\n" <>
        mconcat (sformat (" " % prec 3) <$> toList
                 (L.fold (tDigestQuantiles $ (0.1*) <$> [0..10]) xs)) <>
        "\n    online [min, 10th, 20th, .. 90th, max] with decay rate = 0.996 (one year)\n" <>
        mconcat (sformat (" " % prec 3) <$> toList
                 (L.fold (onlineQuantiles 0.996 $ (0.1*) <$> [0..10]) xs))
{-

digitize
---

-}
    writeFile "other/digitize.md" $
        "\n    first 100 values digitized into quantiles:" <>
        mconcat ((sformat (" " % prec 3) <$>)
                 (take 100 $ L.scan (onlineDigitize 0.996 $ (0.1*) <$> [0..10]) xs))

    fileSvg "other/scratchpad.png" (400,400) $ withChart def (lineChart [def])
        [ zipWith V2 [0..] (L.scan L.sum xs)
        , zipWith V2 [0..] ((2*) <$> L.scan L.sum xs)]

{-
regression
===

-}

costAbs ::
    ( List.ListLike (f a) a
    , Fractional a
    , Foldable f
    , Applicative f) =>
    f a -> f a -> f a -> f (f a) -> a
costAbs ms c ys xss = av
  where
    av = (P./( P.fromIntegral $ length ys)) (L.fold L.sum $ P.abs <$> es)
    es = ys ~-~ (L.fold L.sum <$> (c ~+ (ms ~* xss)))

(~*) :: (Num a, Applicative f) => f a -> f (f a) -> f (f a)
(~*) ms xss = ((<$>) . (P.*)) <$> ms <*> xss

(~+) :: (Num a, Applicative f) => f a -> f (f a) -> f (f a)
(~+) ms xss = ((<$>) . (P.+)) <$> ms <*> xss

(~-~) :: (List.ListLike (f a) a, Num a) => f a -> f a -> f a
(~-~) xs xs' = List.zipWith (P.-) xs xs'

costScan :: (Reifies s Tape) => [Double] -> [Reverse s Double] -> Reverse s Double
costScan xs (m:c:_) = costAbs [m] [c] (auto <$> drop 1 xs) [fmap auto <$> drop 1 $ L.scan (ma 0.99) xs]
costScan xs [] = costAbs [] [] (auto <$> drop 1 xs) [fmap auto <$> drop 1 $ L.scan (ma 0.99) xs]
costScan xs [m] = costAbs [m] [] (auto <$> drop 1 xs) [fmap auto <$> drop 1 $ L.scan (ma 0.99) xs]

grid :: (Field b, FromInteger b, Fractional b) => Range b -> Int -> [b]
grid (Range (l,u)) steps =
    (\a -> l + (u - l) / fromIntegral steps * a) .
    fromIntegral <$>
    [0..steps]

locs0 :: Range Double -> Range Double -> Int -> [V2 Double]
locs0 rx ry steps = [V2 x y | x <- Main.grid rx steps, y <- Main.grid ry steps]

gradF ::
    (forall s. (Reifies s Tape) => [Reverse s Double] -> Reverse s Double) ->
    Double ->
    V2 Double ->
    V2 Double
gradF f step (V2 x y) =
    - r2 ((\[x',y'] -> (x',y')) $
          gradWith (\x0 x1 -> x0 + (x1 - x0) * step) f [x,y])

addGrad ::
    (forall s. (Reifies s Tape) => [Reverse s Double] -> Reverse s Double) ->
    [V2 Double] ->
    Double ->
    [V4 Double]
addGrad f xys step =
    zipWith (\(V2 x y) (V2 z w) -> V4 x y z w) xys (gradF f step <$> xys)

chartGrad :: Rect Double -> Int -> Double -> [Double] -> Chart' a
chartGrad (Rect (V2 rx ry)) grain step xs =
    arrowChart def (V4 one one one one) d <> axes
    (chartAspect .~ asquare $ chartRange .~ Just (rangeR2s [pos]) $ def)
  where
    d = addGrad (costScan xs) pos step
    pos = locs0 rx ry grain

extrap :: [Double] -> (Double, [Double]) -> (Double, [Double])
extrap xs (eta0, x0) = expand eta0 x0
  where
    (res0,_) = grad' (costScan xs) x0
    contract eta x
        | res1 < res0 = (eta, x1)
        | otherwise = contract (eta/2) x1
      where
        x1 = x ~-~ ((eta *) <$> snd (grad' (costScan xs) x))
        res1 = fst $ grad' (costScan xs) x1
    expand eta x
        | res' < res0 = expand (eta*2) x'
        | otherwise = contract (eta/2) x
      where
        x' :: [Double]
        x' = x ~-~ ((eta *) <$> g)
        (_,g) = grad' (costScan xs) x
        (res',_) = grad' (costScan xs) x'

c1 :: Chart SVG -> IO ()
c1 = fileSvg "other/c1.svg" (600,400)

c2 :: Chart SVG -> IO ()
c2 = fileSvg "other/c2.svg" (600,400)

c3 :: Chart SVG -> IO ()
c3 = fileSvg "other/c3.svg" (600,400)

c4 :: Chart SVG -> IO ()
c4 = fileSvg "other/c4.svg" (600,400)


