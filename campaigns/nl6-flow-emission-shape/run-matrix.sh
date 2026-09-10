#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Full matrix: {pre,post} x {5s,30s}. One variable per cell, same host, same
# device, same profile, same window.
set -u
for build in pre post; do
  for tick in 5 30; do
    /tmp/run.sh "$build" "$tick" 300 >> /tmp/matrix.log 2>&1
  done
done
echo "MATRIX COMPLETE" >> /tmp/matrix.log
