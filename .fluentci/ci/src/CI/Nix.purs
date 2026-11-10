module CI.Nix (check, checkWith, capture, run, parseOutputs, parseArtifact, validateSystem, renderReport) where

import Prelude
import Data.Argonaut.Core (Json)
import Data.Argonaut.Decode (class DecodeJson, decodeJson, getField)
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (Either(..), either)
import Data.Foldable (foldl, traverse_)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String as String
import Data.String.Common (trim)
import Data.String.Pattern (Pattern(..))
import Data.Traversable (traverse)
import Effect (Effect)
import Effect.Exception (throw, throwException, try)
import FluentCI.Host.Client (RunResult, TaskResult, TaskStatus(..))
import FluentCI.Host.Files as Files
import FluentCI.Host.Plan as Plan
import FluentCI.Plugin as P
import Foreign.Object as Object

type BuiltOutput = { name :: String, path :: String }
type BinaryReport = { output :: BuiltOutput, binaries :: Array String, versions :: Array String }

-- CLI build logs can precede the final JSON discovery record.
parseArtifact :: String -> Either String String
parseArtifact text = do
  let lines = String.split (Pattern "\n") text
      candidates = Array.mapMaybe (\index -> either (const Nothing) Just
        (jsonParser (String.joinWith "\n" (Array.drop index lines))))
        (Array.reverse (Array.range 0 (Array.length lines - 1)))
  json <- case Array.head candidates of
    Nothing -> Left "FluentCI did not return module discovery JSON"
    Just value -> Right value
  discovery <- decode json :: Either String { modules :: Array { name :: String, wasm :: String } }
  case Array.find (\item -> item.name == "ci") discovery.modules of
    Just item | String.startsWith (Pattern "/") item.wasm && String.endsWith (Pattern ".wasm") item.wasm -> Right item.wasm
    _ -> Left "FluentCI did not return the composed ci component path"

unwrap :: forall a. P.Result a -> Effect a
unwrap = either (throw <<< P.errorMessage) pure

capture :: String -> Array String -> Effect String
capture name args = P.stdout (P.pipeline name # P.exec args) >>= unwrap

run :: String -> Array String -> Effect Unit
run name args = capture name args >>= P.output >>= unwrap

decode :: forall a. DecodeJson a => Json -> Either String a
decode = either (Left <<< show) Right <<< decodeJson

-- Parse the actual build result instead of reevaluating a potentially changed flake.
parseOutputs :: String -> Either String (Array BuiltOutput)
parseOutputs text = do
  json <- jsonParser text
  rows <- decode json :: Either String (Array Json)
  outputs <- traverse (\row -> do
    object <- decode row :: Either String (Object.Object Json)
    fields <- either (Left <<< show) Right (getField object "outputs") :: Either String (Object.Object String)
    pure (map (\name -> { name, path: fromMaybe "" (Object.lookup name fields) }) (Object.keys fields))) rows
  let built = Array.concat outputs
  when (Array.null built) $ Left "Nix did not return any build outputs"
  traverse_ (\output -> unless (String.startsWith (Pattern "/nix/store/") output.path
    && not (String.contains (Pattern "\n") output.path)) (Left "Invalid Nix store output path")) built
  pure built

validateSystem :: Maybe String -> String -> Either String Unit
validateSystem expected actual = do
  unless (Array.elem actual [ "x86_64-linux", "aarch64-linux", "x86_64-darwin", "aarch64-darwin" ]) $
    Left ("Unsupported native Nix platform: " <> actual)
  case expected of
    Just wanted | wanted /= actual -> Left ("Expected " <> wanted <> ", got " <> actual)
    _ -> Right unit

-- Native plans execute argv directly and return failed tasks for inspection.
execute :: Array Plan.Task -> Effect RunResult
execute = executeWith []

-- Setup modules update the compatibility session's environment. Native plans
-- inherit the engine process's original environment, so pass setup values explicitly.
executeWith :: Array { name :: String, value :: String } -> Array Plan.Task -> Effect RunResult
executeWith environment tasks = do
  directory <- trim <$> capture "ci-run-directory" [ "mktemp", "-d" ]
  let configured = map (\task -> foldl (\value variable -> Plan.withEnv variable.name variable.value value) task environment) tasks
  P.runPlan (directory <> "/execution")
    (Plan.plan configured # Plan.withInheritedEnv true # Plan.withJobs 4 # Plan.withFailFast false) >>= unwrap

resultTask :: String -> RunResult -> Effect TaskResult
resultTask name result = case Array.find (\task -> task.id == name) result.tasks of
  Nothing -> throw ("Missing task result: " <> name)
  Just task -> pure task

requireSuccess :: TaskResult -> Effect Unit
requireSuccess result = unless (result.status == TaskSucceeded) $
  throw (result.id <> " failed: " <> fromMaybe result.stderr result.error)

command :: String -> Array String -> Plan.Task
command name args = case Array.uncons args of
  Just { head, tail } -> Plan.task name head "." # Plan.withArgs tail
  Nothing -> Plan.task name "false" "."

fileValue :: forall a. DecodeJson a => String -> Plan.Task -> Effect a
fileValue name task = do
  result <- execute [ task ] >>= resultTask name
  requireSuccess result
  case result.file_result of
    Nothing -> throw (name <> " did not return a file result")
    Just value -> either throw pure (decode value)

reportOutput :: BuiltOutput -> Effect BinaryReport
reportOutput output = do
  names <- fileValue "list-binaries" (Files.list "list-binaries" "bin" output.path) :: Effect (Array String)
  let
    candidates = Array.sort names
    probes = Array.concatMap (\name ->
      [ command ("file-" <> name) [ "test", "-f", output.path <> "/bin/" <> name ] # Plan.allowFailure true
      , command ("exec-" <> name) [ "test", "-x", output.path <> "/bin/" <> name ] # Plan.allowFailure true
      ]) candidates
  checked <- execute probes
  let
    succeeded id = Array.any (\task -> task.id == id && task.status == TaskSucceeded) checked.tasks
    binaries = Array.filter (\name -> succeeded ("file-" <> name) && succeeded ("exec-" <> name)) candidates
  when (Array.null binaries) $ throw ("No executables in " <> output.path <> "/bin")
  versions <- traverse (\name -> trim <$> capture (name <> "-version")
    [ output.path <> "/bin/" <> name, "--version" ])
    (Array.filter (flip Array.elem binaries) [ "postgres", "pgstream" ])
  pure { output, binaries, versions }

renderReport :: Array BinaryReport -> String
renderReport reports = "## Built Nix binaries\n\n" <> String.joinWith "\n" (map render reports)
  where
  render report = "### " <> report.output.path <> " (" <> report.output.name <> ")\n\n```text\n"
    <> String.joinWith "\n" (map (\binary -> report.output.path <> "/bin/" <> binary) report.binaries)
    <> "\n```\n\n" <> String.joinWith "\n" (map (\version -> "```text\n" <> version <> "\n```\n") report.versions)

report :: Array BuiltOutput -> Effect Unit
report outputs = do
  text <- renderReport <$> traverse reportOutput outputs
  P.output text >>= unwrap
  hasSummary <- P.hasEnv "GITHUB_STEP_SUMMARY" >>= unwrap
  when hasSummary do
    path <- P.getEnv "GITHUB_STEP_SUMMARY" >>= unwrap
    let segments = String.split (Pattern "/") path
        name = fromMaybe "" (Array.last segments)
        directory = String.joinWith "/" (Array.dropEnd 1 segments)
    unless (String.startsWith (Pattern "/") path && name /= "") $ throw "Invalid GITHUB_STEP_SUMMARY path"
    old <- fileValue "read-summary" (Files.readText "read-summary" name 1048576 directory) :: Effect String
    result <- execute [ Files.writeText "write-summary" name (old <> text) true directory ] >>= resultTask "write-summary"
    requireSuccess result

-- | Verify the platform, build pinned packages, run smoke checks and report binaries even if checks fail.
check :: { system :: Maybe String } -> Effect Unit
check = checkWith []

checkWith :: Array { name :: String, value :: String } -> { system :: Maybe String } -> Effect Unit
checkWith environment args = do
  run "nix-version" [ "nix", "--version" ]
  actual <- trim <$> capture "native-platform" [ "nix", "eval", "--impure", "--raw", "--expr", "builtins.currentSystem" ]
  either throw pure (validateSystem args.system actual)
  built <- executeWith environment [ command "nix-build"
    [ "nix", "build", "--json", "--no-link", "--no-write-lock-file", "--print-build-logs"
    , ".#postgres18", ".#postgres19", ".#pgstream" ] ] >>= resultTask "nix-build"
  requireSuccess built
  outputs <- either throw pure (parseOutputs built.stdout)
  checked <- try do
    task <- executeWith environment [ command "nix-check" [ "nix", "flake", "check", "--no-write-lock-file", "--print-build-logs" ] ] >>= resultTask "nix-check"
    requireSuccess task
  reported <- try (report outputs)
  -- Keep the original test failure when both checks and reporting fail.
  either throwException (const (either throwException pure reported)) checked
