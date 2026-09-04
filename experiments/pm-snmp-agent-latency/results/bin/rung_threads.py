# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
"""One knee rung at a different Collectd pool size, fleet held.

Sets threads in collectd-configuration.xml (pool_sweep's guarded setter),
restarts OpenNMS, waits for a steady queue, then hands the measurement to
knee_search at the current fleet so the record has the same shape and
criterion as the search it extends.

    rung_threads.py <results_dir> --threads 300 --fleet 12250 --label pool300-mr5
"""
import argparse
import importlib.util
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ap = argparse.ArgumentParser()
ap.add_argument("out")
ap.add_argument("--threads", type=int, required=True)
ap.add_argument("--fleet", type=int, required=True)
ap.add_argument("--label", required=True)
a = ap.parse_args()

ps = load("pool_sweep")
ps.OUT = a.out
ps.LOG = os.path.join(a.out, f"knee-search-{a.label}.log")
ps.RESULTS = os.path.join(a.out, f"knee-search-{a.label}.jsonl")

ps.log(f"rung at threads={a.threads}, fleet held at {a.fleet:,}")
ps.set_threads(a.threads)
ps.log(f"  collectd-configuration.xml threads={a.threads}, restarting")
ps.restart_and_wait()
ps.log("  waiting for one cycle, a drained queue, then settle")
ps.wait_steady()
ps.log("  handing over to knee_search for the window")
sys.exit(subprocess.call([sys.executable, os.path.join(HERE, "knee_search.py"), a.out,
                          "--start", str(a.fleet), "--cap", str(a.fleet), "--label", a.label]))
