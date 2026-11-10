import test from "node:test";
import assert from "node:assert/strict";
import { check, checkWith, parseOutputs, parseArtifact, validateSystem } from "../output/CI.Nix/index.js";
import { Nothing, Just } from "../output/Data.Maybe/index.js";
import { Left, Right } from "../output/Data.Either/index.js";

const outputPaths = ["/nix/store/fixture-postgres18", "/nix/store/fixture-postgres19", "/nix/store/fixture-pgstream"];
const buildJson = JSON.stringify(outputPaths.map(path => ({ outputs: { out: path } })));

// Exercise compiled PureScript with a host double. Never execute real Nix commands.
function fixture(options = {}) {
  const calls = [];
  const output = [];
  const summaries = [];
  const journal = new Map();
  const env = options.summary === false ? {} : { GITHUB_STEP_SUMMARY: "/tmp/actions/summary.md" };
  let pipeline = "";
  let command = [];
  let counter = 0;
  const unquote = value => value.slice(1, -1).replaceAll("'\\''", "'");
  const taskResult = (task, data = {}) => ({
    id: task.id, status: "succeeded", exit_code: 0, error: null, duration_ms: 1,
    stdout: "", stderr: "", cache: { outcome: "disabled", key: null, reason: "fixture" },
    wait_reason: null, outputs: null, artifacts: null, attempts: null, signal: null,
    file_result: null, condition_skipped: false, allowed_failure: false, ...data,
  });
  globalThis.Memory = {
    fromString: value => ({ offset: value }),
    find: value => ({ readString: () => value }),
  };
  globalThis.Host = {
    outputString: value => output.push(value),
    getFunctions: () => new Proxy({}, {
      get: (_, name) => value => {
        calls.push([name, value]);
        switch (name) {
          case "pipeline": pipeline = value; return JSON.stringify({ id: "fixture" });
          case "with_exec": command = JSON.parse(value).map(unquote); return "";
          case "has_env": return JSON.stringify(Object.hasOwn(env, value));
          case "get_env": return env[value] ?? "";
          case "stdout":
            if (pipeline === "ci-run-directory") return `/tmp/ci-${counter++}`;
            if (pipeline === "native-platform") return options.system ?? "x86_64-linux";
            if (pipeline.endsWith("-version")) {
              assert.equal(command[1], "--version");
              return `${pipeline} fixture-version`;
            }
            throw Error(`Unexpected command: ${pipeline}`);
          case "output": output.push(value); return "";
          case "execute_plan": {
            const request = JSON.parse(value);
            const tasks = request.plan.tasks.map(task => {
              if (task.id === "nix-build") {
                assert.deepEqual(task.args, ["build", "--json", "--no-link", "--no-write-lock-file", "--print-build-logs", ".#postgres18", ".#postgres19", ".#pgstream"]);
                const stdout = `${request.run_dir}/0.stdout`;
                journal.set(stdout, options.buildJson ?? buildJson);
                return taskResult(task, options.buildFailure
                  ? { status: "failed", exit_code: 1, error: "build failed" }
                  : { stdout });
              }
              if (task.id === "nix-check") return taskResult(task, options.checkFailure
                ? { status: "failed", exit_code: 1, error: "restore failed" } : {});
              if (task.file_operation?.op === "list") {
                if (options.reportFailure) throw Error("report listing failed");
                const binaries = task.cwd.endsWith("pgstream") ? ["pgstream"] : ["psql", "postgres", "pgstream", "not-executable"];
                return taskResult(task, { file_result: binaries });
              }
              if (task.id.startsWith("file-") || task.id.startsWith("exec-")) {
                return taskResult(task, task.id === "exec-not-executable"
                  ? { status: "failed", exit_code: 1, allowed_failure: true } : {});
              }
              if (task.file_operation?.op === "read_text") {
                const path = `${task.cwd}/${task.file_operation.path}`;
                if (path === env.GITHUB_STEP_SUMMARY) return taskResult(task, { file_result: "Previous summary\n" });
                assert.ok(journal.has(path), `Missing task journal: ${path}`);
                return taskResult(task, { file_result: journal.get(path) });
              }
              if (task.file_operation?.op === "write_text") {
                summaries.push(task.file_operation.text);
                return taskResult(task);
              }
              throw Error(`Unexpected task: ${JSON.stringify(task)}`);
            });
            const outcome = tasks.some(task => task.status === "failed" && !task.allowed_failure) ? "failed" : "succeeded";
            return JSON.stringify({ tasks, outcome });
          }
          default: return "";
        }
      },
    }),
  };
  return { calls, output, summaries };
}

const plans = f => f.calls.filter(([name]) => name === "execute_plan").map(([, value]) => JSON.parse(value).plan);

test("parses actual Nix outputs and rejects malformed or empty results", () => {
  assert.ok(parseOutputs(buildJson) instanceof Right);
  for (const value of ["not JSON", "[]", '[{"outputs":{"out":"/tmp/untrusted"}}]', '[{}]']) {
    assert.ok(parseOutputs(value) instanceof Left);
  }
});

test("platform mismatch is rejected before building", () => {
  assert.ok(validateSystem(new Just("aarch64-linux"))("x86_64-linux") instanceof Left);
  assert.ok(validateSystem(Nothing.value)("x86_64-darwin") instanceof Right);
  const f = fixture();
  assert.throws(() => check({ system: new Just("aarch64-linux") })(), /Expected aarch64-linux/);
  assert.equal(plans(f).length, 0);
});

test("reports all executable paths and correct version flags after successful checks", () => {
  const f = fixture();
  check({ system: new Just("x86_64-linux") })();
  const ordered = plans(f).flatMap(plan => plan.tasks.map(task => task.id));
  assert.ok(ordered.indexOf("nix-build") < ordered.indexOf("nix-check"));
  assert.ok(ordered.indexOf("nix-build") < ordered.indexOf("read-build-stdout"));
  assert.ok(ordered.indexOf("read-build-stdout") < ordered.indexOf("nix-check"));
  assert.ok(ordered.indexOf("nix-check") < ordered.indexOf("list-binaries"));
  const report = f.output.find(value => value.startsWith("## Built Nix binaries"));
  for (const path of outputPaths) assert.ok(report.includes(`${path}/bin/pgstream`));
  assert.ok(report.includes("/bin/postgres"));
  assert.ok(report.includes("/bin/psql"));
  assert.ok(!report.includes("not-executable"));
  assert.deepEqual(f.summaries, [`Previous summary\n${report}`]);
});

test("still reports built binaries after smoke checks fail", () => {
  const f = fixture({ checkFailure: true });
  assert.throws(() => check({ system: Nothing.value })(), /restore failed/);
  assert.equal(f.summaries.length, 1);
  assert.ok(f.summaries[0].includes("/bin/pgstream"));
});

test("passes the setup component's PATH and certificate environment to both native Nix tasks", () => {
  const f = fixture();
  const environment = [
    { name: "PATH", value: "/nix/var/nix/profiles/default/bin:/usr/bin:/bin" },
    { name: "NIX_SSL_CERT_FILE", value: "/etc/ssl/certs/ca-certificates.crt" },
  ];
  checkWith(environment)({ system: Nothing.value })();
  const native = plans(f).flatMap(plan => plan.tasks).filter(task => task.id === "nix-build" || task.id === "nix-check");
  assert.equal(native.length, 2);
  for (const task of native) {
    assert.deepEqual(task.env, Object.fromEntries(environment.map(({ name, value }) => [name, value])));
  }
});

test("preserves the original test failure if reporting also fails", () => {
  fixture({ checkFailure: true, reportFailure: true });
  assert.throws(() => check({ system: Nothing.value })(), /restore failed/);
});

test("report failure fails an otherwise successful run", () => {
  fixture({ reportFailure: true });
  assert.throws(() => check({ system: Nothing.value })(), /report listing failed/);
});

test("failed or malformed build results never run smoke checks or reports", () => {
  for (const options of [{ buildFailure: true }, { buildJson: "[]" }]) {
    const f = fixture(options);
    assert.throws(() => check({ system: Nothing.value })());
    assert.deepEqual(plans(f).flatMap(plan => plan.tasks.map(task => task.id)),
      options.buildFailure ? ["nix-build"] : ["nix-build", "read-build-stdout"]);
    assert.equal(f.summaries.length, 0);
  }
});

test("local reporting works without GitHub summary environment", () => {
  const f = fixture({ summary: false });
  check({ system: Nothing.value })();
  assert.ok(f.output.some(value => value.includes("## Built Nix binaries")));
  assert.equal(f.summaries.length, 0);
});

test("finds the composed component in CLI discovery after compiler logs", () => {
  const artifact = "/tmp/cache/composed.wasm";
  const result = parseArtifact(`Compiling...\n${JSON.stringify({ modules: [{ name: "ci", wasm: artifact }] }, null, 2)}\n`);
  assert.ok(result instanceof Right);
  assert.equal(result.value0, artifact);
  assert.ok(parseArtifact('{"modules":[]}') instanceof Left);
});
