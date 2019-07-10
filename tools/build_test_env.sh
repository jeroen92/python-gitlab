#!/bin/sh
# Copyright (C) 2016 Gauvain Pocentek <gauvain@pocentek.net>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

pecho() { printf %s\\n "$*"; }
log() {
    [ "$#" -eq 0 ] || { pecho "$@"; return 0; }
    while IFS= read -r log_line || [ -n "${log_line}" ]; do
        log "${log_line}"
    done
}
error() { log "ERROR: $@" >&2; }
fatal() { error "$@"; exit 1; }
try() { "$@" || fatal "'$@' failed"; }

NOVENV=
PY_VER=3
API_VER=4
while getopts :np:a: opt "$@"; do
    case $opt in
        n) NOVENV=1;;
        p) PY_VER=$OPTARG;;
        a) API_VER=$OPTARG;;
        :) fatal "Option -${OPTARG} requires a value";;
        '?') fatal "Unknown option: -${OPTARG}";;
        *) fatal "Internal error: opt=${opt}";;
    esac
done

case $PY_VER in
    2) VENV_CMD=virtualenv;;
    3) VENV_CMD="python3 -m venv";;
    *) fatal "Wrong python version (2 or 3)";;
esac

case $API_VER in
    4) ;;
    *) fatal "Wrong API version (4 only)";;
esac

for req in \
    curl \
    docker \
    ;
do
    command -v "${req}" >/dev/null 2>&1 || fatal "${req} is required"
done

VENV=$(pwd)/.venv || exit 1
CONFIG=/tmp/python-gitlab.cfg

cleanup() {
    rm -f "${CONFIG}"
    log "Deactivating Python virtualenv..."
    command -v deactivate >/dev/null 2>&1 && deactivate || true
    log "Deleting python virtualenv..."
    rm -rf "$VENV"
    log "Stopping gitlab-test docker container..."
    docker rm -f gitlab-test >/dev/null
    log "Done."
}
[ -z "${BUILD_TEST_ENV_AUTO_CLEANUP+set}" ] || {
    trap cleanup EXIT
    trap 'exit 1' HUP INT TERM
}

try docker run --name gitlab-test --detach --publish 8080:80 \
    --publish 2222:22 registry.gitlab.com/python-gitlab/python-gitlab:test >/dev/null

LOGIN='root'
PASSWORD='5iveL!fe'
GITLAB() { gitlab --config-file "$CONFIG" "$@"; }
GREEN='\033[0;32m'
NC='\033[0m'
OK() { printf "${GREEN}OK${NC}\\n"; }
testcase() {
    testname=$1; shift
    testscript=$1; shift
    printf %s "Testing ${testname}... "
    eval "${testscript}" || fatal "test failed"
    OK
}

if [ -z "$NOVENV" ]; then
    log "Creating Python virtualenv..."
    try $VENV_CMD "$VENV"
    . "$VENV"/bin/activate || fatal "failed to activate Python virtual environment"

    log "Installing dependencies into virtualenv..."
    try pip install -rrequirements.txt

    log "Installing into virtualenv..."
    try pip install -e .

    # to run generate_token.py
    pip install bs4 lxml
fi

log "Waiting for gitlab to come online... "
I=0
while :; do
    sleep 1
    docker top gitlab-test >/dev/null 2>&1 || fatal "docker failed to start"
    sleep 4
    curl -s http://localhost:8080/users/sign_in 2>/dev/null \
        | grep -q "GitLab Community Edition" && break
    I=$((I+5))
    [ "$I" -lt 180 ] || fatal "timed out"
done

# Get the token
TOKEN=$($(dirname $0)/generate_token.py)
echo $TOKEN

cat > $CONFIG << EOF
[global]
default = local
timeout = 10

[local]
url = http://localhost:8080
private_token = $TOKEN
api_version = $API_VER
EOF

log "Config file content ($CONFIG):"
log <$CONFIG

log "Pausing to give GitLab some time to finish starting up..."
sleep 500

log "Test environment initialized."
