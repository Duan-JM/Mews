#!/usr/bin/env bash

mews_parse_version() {
  local version="${1:-}"
  local version_re='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-dev(\.([1-9][0-9]*))?)?$'

  if [[ "$version" == "dev" ]]; then
    APP_SHORT_VERSION="0.0.0"
    APP_BUILD_VERSION="0"
    CASK_VERSION="0.0.0-dev"
    CASK_TOKEN="mews@dev"
    CASK_FILENAME="${CASK_TOKEN}.rb"
  elif [[ "$version" =~ $version_re ]]; then
    APP_SHORT_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
    APP_BUILD_VERSION="$APP_SHORT_VERSION"
    CASK_VERSION="${version#v}"
    if [[ -n "${BASH_REMATCH[4]}" ]]; then
      CASK_TOKEN="mews@dev"
    else
      CASK_TOKEN="mews"
    fi
    CASK_FILENAME="${CASK_TOKEN}.rb"
  else
    echo "VERSION must be dev, v1.2.3, or v1.2.3-dev.1 (got: ${version:-unset})" >&2
    return 1
  fi

  export APP_SHORT_VERSION APP_BUILD_VERSION CASK_VERSION CASK_TOKEN CASK_FILENAME
}

mews_require_release_version() {
  local version="${1:-}"
  if [[ "$version" == "dev" ]]; then
    echo "VERSION must be a tagged version such as v1.2.3 or v1.2.3-dev.1" >&2
    return 1
  fi
  mews_parse_version "$version"
}
