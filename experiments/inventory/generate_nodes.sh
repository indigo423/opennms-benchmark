#!/usr/bin/env bash

FILENAME=tmp-nodes.xml
# Script iterates over 10.42.0.0/16 network
# Network range: 10.42.0.0 to 10.42.255.255
# Usable IPs: 10.42.0.1 to 10.42.255.254 (excluding network and broadcast)

# Counter for processed IPs
counter=9206

printf '<?xml version="1.0" encoding="UTF-8"?>
<model-import xmlns="http://xmlns.opennms.org/xsd/config/model-import" date-stamp="2016-10-28T10:50:02.025Z" foreign-source="demo-environment" last-import="2016-10-28T10:51:29.354Z">\n' > "${FILENAME}"

# Outer loop for third octet (0-255)
for third_octet in {36..39}; do
    # Inner loop for fourth octet (1-254 for first/last subnet, 0-255 for middle subnets)
    if [ "$third_octet" -eq 0 ]; then
        # First subnet: skip .0 (network address)
        start_fourth=1
    else
        start_fourth=0
    fi

    if [ "$third_octet" -eq 39 ]; then
        # Last subnet: skip .255 (broadcast address)
        end_fourth=254
    else
        end_fourth=255
    fi

    for fourth_octet in $(seq $start_fourth $end_fourth); do
        ip="10.42.$third_octet.$fourth_octet"
        counter=$((counter + 1))

        printf '  <node location="lab-location-01" foreign-id="node-%s" node-label="node-%s">
    <interface ip-addr="%s" status="1" snmp-primary="P">
      <monitored-service service-name="ICMP"/>
      <monitored-service service-name="SNMP"/>
    </interface>
  </node>\n' "${counter}" "${counter}" "${ip}" >> "${FILENAME}"
    done
done

printf '</model-import>\n' >> "${FILENAME}"
