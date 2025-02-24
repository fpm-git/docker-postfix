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

cache_from="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )/cache"
cache_to="${cache_from}"

if ! docker buildx inspect multiarch > /dev/null; then
    docker buildx create --name multiarch
fi
docker buildx use multiarch

if [[ "$*" == *--push* ]]; then
    if [[ -n "$DOCKER_USERNAME" ]] && [[ -n "$DOCKER_PASSWORD" ]]; then
        echo "Logging into docker registry $DOCKER_REGISTRY_URL...."
        echo "$DOCKER_PASSWORD" | docker login --username $DOCKER_USERNAME --password-stdin $DOCKER_REGISTRY_URL
    fi
fi

arg_list=" --cache-to type=local,dest=${cache_to}"
if [[ -f "${cache_from}/index.json" ]]; then
    arg_list="$arg_list --cache-from type=local,src=${cache_from}"
else
    mkdir -p "${cache_from}"
fi

#if [[ -z "$PLATFORMS" ]]; then
#    arg_list="$arg_list --platform linux/amd64,linux/arm64,linux/arm/v7"
#fi

set -x
exec docker buildx build ${arg_list} $* .

