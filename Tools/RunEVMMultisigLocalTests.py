#!/usr/bin/env python3
"""Execute production Swift Safe signing against a disposable local EVM.
Requires Node/npm and Swift; installs pinned JS test dependencies into a temporary
folder. No simulator, account login, public network wallet, or mainnet spending.
"""
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
with socket.socket() as probe:
    if probe.connect_ex(("127.0.0.1", 18547)) == 0:
        raise SystemExit("Port 18547 is occupied. Stop your previous fixture before running this test.")
with tempfile.TemporaryDirectory(prefix="oath-safe-local-") as folder:
    work = Path(folder)
    subprocess.run(["npm", "install", "--prefix", folder, "--cache", str(work / "cache"),
                    "--ignore-scripts", "--legacy-peer-deps", "--no-audit", "--no-fund",
                    "ganache@7.9.2", "ethers@6.17.0", "solc@0.8.37",
                    "@safe-global/safe-contracts@1.4.1"], check=True)
    env = dict(os.environ, NODE_PATH=str(work / "node_modules"), OATH_SAFE_LOCAL="1")
    with (work / "fixture.log").open("w+") as log:
        fixture = subprocess.Popen(["node", str(ROOT / "Tools/Fixtures/EVMMultisig/local.cjs")], env=env, stdout=log, stderr=log)
        try:
            for _ in range(120):
                log.seek(0)
                if "SAFE_LOCAL_READY" in log.read():
                    break
                if fixture.poll() is not None:
                    raise RuntimeError("Local fixture failed; no public transactions were attempted.")
                time.sleep(0.25)
            else:
                raise RuntimeError("Local fixture startup timed out")
            subprocess.run(["swift", "test", "--package-path", str(ROOT / "Packages/OathAnkr"),
                            "--scratch-path", "/tmp/oath-evm-ankr-host", "--filter", "EVMMultisigTests"], env=env, check=True)
        finally:
            fixture.terminate()
            try:
                fixture.wait(timeout=10)
            except subprocess.TimeoutExpired:
                fixture.kill()
                fixture.wait()
