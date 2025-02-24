#!/bin/sh
cd unit-tests

DOCKER_COMPOSE="docker-compose"
if docker --help | grep -q -F 'compose*'; then
    DOCKER_COMPOSE="docker compose"
fi

$DOCKER_COMPOSE up --build --abort-on-container-exit --exit-code-from tests
