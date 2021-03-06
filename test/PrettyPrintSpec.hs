module PrettyPrintSpec where

import Test.Hspec
import PrettyPrint
import qualified Value as V

spec :: Spec
spec = it "prints values" $ do
    V.Integer 1 `prints` "1"
    V.String "string" `prints` "\"string\""
    constructor "Just" [V.Integer 1] `prints` "Just 1"
    constructor "Just" [constructor "True" []] `prints` "Just True"
    constructor "Just" [constructor "Just" [V.Integer 1]] `prints` "Just (Just 1)"

prints :: V.Value String -> String -> Expectation
prints v s = prettyPrintValue id v `shouldBe` Just s

constructor :: String -> [V.Value String] -> V.Value String
constructor name values = V.Constructor name $ fmap Just values
