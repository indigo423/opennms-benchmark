#!/bin/bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
# usage: level.sh <on|off> <25|50|75|100>
# Silent drop of whole /24 blocks of the 11,000-device fleet (octets 0-43, 250 devices each)
# on netsim's FORWARD chain, ahead of the ACCEPT that carries SNMP into nl6's namespace.
set -u
ACT=$1; LVL=$2
case $LVL in
  25)  NETS="10.42.0.0/21 10.42.8.0/23 10.42.10.0/24" ;;          # octets 0-10: 11 blocks, 2,750 devices
  50)  NETS="10.42.0.0/20 10.42.16.0/22 10.42.20.0/23" ;;         # octets 0-21: 22 blocks, 5,500
  75)  NETS="10.42.0.0/19 10.42.32.0/24" ;;                        # octets 0-32: 33 blocks, 8,250
  100) NETS="10.42.0.0/18" ;;                                      # octets 0-63: all 44 blocks, 11,000
  *) echo "level?"; exit 2 ;;
esac
S="ssh -o BatchMode=yes -o ConnectTimeout=25 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -J labuser@192.168.10.40 labuser@netsim-benchmark-01"
for n in $NETS; do
  if [ "$ACT" = on ]; then $S "sudo -n iptables -I FORWARD 1 -o veth-sim-host -d $n -j DROP" 2>/dev/null
  else $S "sudo -n iptables -D FORWARD -o veth-sim-host -d $n -j DROP" 2>/dev/null; fi
done
$S 'sudo -n iptables -L FORWARD -n --line-numbers | grep -c DROP' 2>/dev/null | tail -1 | sed 's/^/drop rules now: /'
date -u +%FT%TZ
