# Optional reference builder: golang image + source mount (see vw-build.sh).
ARG BUILDER_IMAGE=docker.io/library/golang:1.24.5-bookworm
FROM ${BUILDER_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates git make && rm -rf /var/lib/apt/lists/*
WORKDIR /go/src/github.com/openshift/installer
ENV CGO_ENABLED=0 GOTOOLCHAIN=auto
