#!/bin/sh
cd $(dirname $0)

DOCKER_COMPOSE="docker-compose"
if docker --help | grep -q -F 'compose*'; then
    DOCKER_COMPOSE="docker compose"
fi

$DOCKER_COMPOSE up