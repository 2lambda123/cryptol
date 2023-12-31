#!/usr/bin/env runhaskell

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}

-- |
-- Module      :  Main
-- Copyright   :  (c) 2013-2016 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable

import Cryptol.Parser.Lexer
import Cryptol.Parser.Position
import Cryptol.Utils.PP
import qualified Data.Text.IO as Text
import Text.Blaze.Html (Html, AttributeValue, toHtml, (!), toValue)
import qualified Text.Blaze.Html as H
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A
import Text.Blaze.Html.Renderer.String (renderHtml)


main :: IO ()
main =
  do txt <- Text.getContents
     putStrLn $ renderHtml
              $ page
              $ toHtml
              $ map toBlaze
              $ fst
              $ primLexer defaultConfig txt

page :: Html -> Html
page inner = do
    H.docTypeHtml ! A.xmlns "http://www.w3.org/1999/xhtml" $ do
        H.head $ do
            H.meta ! A.httpEquiv "Content-Type" ! A.content "text/html; charset=UTF-8"
            H.title "Cryptol Source"
            H.style $ H.preEscapedString sty
        H.body inner


toBlaze :: Located Token -> Html
toBlaze (Located _ (tokenType -> EOF)) = mempty
toBlaze tok = H.span ! (A.class_ $ cl $ tokenType $ thing tok)
                     ! (A.id $ toValue $ show $ pp $ from $ srcRange tok)
  $ H.toHtml
  $ tokenText
  $ thing tok


cl :: TokenT -> AttributeValue
cl tok =
  case tok of
        Num {}      -> "number"
        Frac {}     -> "number"
        Ident {}    -> "identifier"
        Selector {} -> "selector"
        KW {}       -> "keyword"
        Op {}       -> "operator"
        Sym {}      -> "symbol"
        Virt {}     -> "virtual"
        White Space -> "white"
        White _     -> "comment"
        Err {}      -> "error"
        EOF         -> "eof"
        StrLit {}   -> "text"
        ChrLit {}   -> "text"



sty :: String
sty = unlines
  [ "body { font-family: monospace; white-space: pre; }"
  , ".number        { color: #cc00cc }"
  , ".identifier    { }"
  , ".selector      { color: #33033 }"
  , ".keyword       { color: blue; }"
  , ".operator      { color: #cc00cc }"
  , ".symbol        { color: blue }"
  , ".white         { }"
  , ".virtual       { background-color: red }"
  , ".comment       { color: green }"
  , ".error         { color: red }"
  , ".text          { color: #cc00cc }"
  ]

