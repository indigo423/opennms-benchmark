# syntax=docker/dockerfile:1
# Builds the l8opensim SNMP simulator from source.
# The SNMP port (161) is hardcoded in constants.go and is not configurable
# via flags. Each simulated device binds UDP 161 on its own TUN interface IP.
FROM golang:1.23-bookworm AS builder
ENV GOTOOLCHAIN=auto
RUN apt-get update && apt-get install -y --no-install-recommends git && rm -rf /var/lib/apt/lists/*
ARG L8OPENSIM_REF=main
RUN git clone --depth 1 --branch ${L8OPENSIM_REF} https://github.com/saichler/l8opensim.git /src
WORKDIR /src/go/simulator
RUN go build -mod=mod -o /simulator .

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    iproute2 iptables ca-certificates && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /home/run
COPY --from=builder /simulator ./simulator
COPY --from=builder /src/go/simulator/resources/ ./resources/
COPY --from=builder /src/go/simulator/worldcities/ ./worldcities/
COPY --from=builder /src/go/simulator/web/ ./web/
ENTRYPOINT ["./simulator"]
