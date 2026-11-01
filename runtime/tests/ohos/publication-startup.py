#!/usr/bin/env python3
"""Real Node startup controls; no SDK/target-ABI claim is made."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser()
    for name in ("node", "simulation", "linked-lib", "out"):
        parser.add_argument("--" + name, required=True, type=Path)
    args = parser.parse_args()
    runtime = Path(__file__).resolve().parents[2]
    preload = runtime / "ohos/publication/preload.mjs"
    index = runtime / "ohos/publication/index.mjs"
    probe = "console.log(JSON.stringify({platform:process.platform,installed:!!globalThis[Symbol.for('dsh.go.ohos.publication')]}))"
    worker_probe = """import { Worker } from 'node:worker_threads';
const worker = new Worker("import {parentPort,isMainThread} from 'node:worker_threads'; parentPort.postMessage({installed:!!globalThis[Symbol.for('dsh.go.ohos.publication')],isMainThread});", {eval:true});
const [result] = await Promise.all([
new Promise((resolve,reject)=>{worker.once('message',resolve);worker.once('error',reject);}),
new Promise((resolve,reject)=>{worker.once('exit',code=>code===0?resolve():reject(new Error('worker exit '+code)));})]);
console.log(JSON.stringify(result));"""
    cases = [
        ("ordinary-linux", False, False, True, {}, probe, {"platform": "linux", "installed": False}, None),
        ("environment-alone", False, False, True, {"DSH_GO_OHOS_SIM": "1", "DSH_GO_OHOS_SIM_PLATFORM": "openharmony"}, probe, {"platform": "linux", "installed": False}, None),
        ("strict-linked", True, True, True, {}, probe, {"platform": "openharmony", "installed": True}, None),
        ("strict-missing-binding", True, False, True, {}, probe, None, "ERR_OHOS_PUBLICATION_BINDING_MISSING"),
        ("duplicate-install", True, True, True, {}, f"import {{installPublication}} from {json.dumps(index.as_uri())};installPublication();", None, "ERR_OHOS_PUBLICATION_DUPLICATE"),
        ("wrong-node-version", True, False, False, {}, f"import {{installPublication}} from {json.dumps(index.as_uri())};Object.defineProperty(process.versions,'node',{{value:'24.0.0'}});installPublication();", None, "ERR_OHOS_PUBLICATION_NODE_VERSION"),
        ("worker-inherited-preload", True, True, True, {}, worker_probe, {"installed": False, "isMainThread": False}, None),
    ]
    rows = []
    for name, simulation, linked, install, additions, source, expected, error in cases:
        env = os.environ.copy()
        for key in ("LD_PRELOAD", "DSH_GO_OHOS_SIM", "DSH_GO_OHOS_SIM_PLATFORM", "DSH_GO_OHOS_SIM_ADDONS", "NODE_OPTIONS"):
            env.pop(key, None)
        env.update(additions)
        argv = [str(args.node.resolve()), "--jitless"]
        if simulation:
            argv += ["--import", str(args.simulation.resolve())]
            env["DSH_GO_OHOS_SIM_PLATFORM"] = "openharmony"
        if linked:
            env["LD_PRELOAD"] = str(args.linked_lib.resolve())
        if install:
            argv += ["--import", str(preload)]
        argv += ["--input-type=module", "--eval", source]
        result = subprocess.run(argv, env=env, text=True, capture_output=True, timeout=15)
        passed = (result.returncode != 0 and error in result.stderr) if error else (result.returncode == 0 and json.loads(result.stdout) == expected)
        rows.append({"case": name, "passed": passed, "exit": result.returncode, "argv": argv, "stdout": result.stdout, "stderr": result.stderr})
        print(name, "PASS" if passed else "FAIL")
    inputs = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in (args.node, args.simulation, args.linked_lib, preload, index)}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps({"scope": "Linux startup controls with own linked fixture", "inputs": inputs, "cases": rows}, indent=2) + "\n")
    return 0 if all(row["passed"] for row in rows) else 1


if __name__ == "__main__":
    raise SystemExit(main())
