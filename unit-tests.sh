#!/bin/sh
set -u
set -x
cd unit-tests

if command -v docker >/dev/null 2>&1; then
    DOCKER_COMPOSE="docker-compose"
    if docker --help | grep -q -F 'compose*'; then
        DOCKER_COMPOSE="docker compose"
    fi
elif command -v podman >/dev/null 2>&1; then
    DOCKER_COMPOSE="podman compose"
else
    echo "Neither `docker` or `podman` installed. Cannot execute tests."
    exit 1
fi

$DOCKER_COMPOSE up --build --abort-on-container-exit --exit-code-from tests
