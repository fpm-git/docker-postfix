#!/usr/bin/env bash
set -e
# Do a multistage build

export DOCKER_BUILDKIT=1
export DOCKER_CLI_EXPERIMENTAL=enabled
export BUILDKIT_PROGRESS=plain

declare cache_dir
declare arg_list

if [[ "$CI" == "true" ]]; then
    if [[ -f "/tmp/.buildx-cache/alpine/index.json" ]]; then
        arg_list="$arg_list --cache-from type=local,src=/tmp/.buildx-cache/alpine/index.json"
    fi
fi

if command -v docker >/dev/null 2>&1; then
    DOCKER="docker"
elif command -v podman >/dev/null 2>&1; then
    DOCKER="podman"
else
    echo "Neither `docker` or `podman` installed. Cannot execute tests."
    exit 1
fi


if ! ${DOCKER} buildx inspect multiarch > /dev/null; then
    ${DOCKER} buildx create --name multiarch
fi

if [[ "${DOCKER}" == "docker" ]]; then
    cache_from="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )/cache"
    cache_to="${cache_from}"
    ${DOCKER} buildx use multiarch
fi

if [[ "$*" == *--push* ]]; then
    if [[ -n "$DOCKER_USERNAME" ]] && [[ -n "$DOCKER_PASSWORD" ]]; then
        echo "Logging into docker registry $DOCKER_REGISTRY_URL...."
        echo "$DOCKER_PASSWORD" | ${DOCKER} login --username $DOCKER_USERNAME --password-stdin $DOCKER_REGISTRY_URL
    fi
fi

if [[ -n "${cache_to}" ]]; then
    arg_list=" --cache-to type=local,dest=${cache_to}"
fi

if [[ -n "${cache_from}" ]]; then
    if [[ -f "${cache_from}/index.json" ]]; then
        arg_list="$arg_list --cache-from type=local,src=${cache_from}"
    else
        mkdir -p "${cache_from}"
    fi
fi

set -x
exec ${DOCKER} buildx build ${arg_list} $* .

