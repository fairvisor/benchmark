#!/usr/bin/env bash
##############################################################################
# run-all.sh — Fairvisor Benchmark Suite
#
# Supported modes:
#   1. Local single-host:
#        bash run-all.sh
#   2. Local controller + two remote hosts:
#        FAIRVISOR_REMOTE=ubuntu@fairvisor \
#        LOADGEN_REMOTE=ubuntu@loadgen \
#        FAIRVISOR_TARGET_HOST=10.0.0.42 \
#        bash run-all.sh
#
# In remote mode, this script stays on the local machine and orchestrates:
#   - one remote Fairvisor host (OpenResty + backend + SUT)
#   - one remote load-generator host (k6 only)
##############################################################################
set -euo pipefail

##############################################################################
# CONFIG
##############################################################################
FV_DIR="${FV_DIR:-/opt/fairvisor}"
BENCH_DIR="${BENCH_DIR:-/tmp/fv-bench}"
K6_VER="${K6_VER:-v0.54.0}"

FV_PORT="${FV_PORT:-8080}"
BACKEND_PORT="${BACKEND_PORT:-8081}"
NGINX_PORT="${NGINX_PORT:-8082}"

LATENCY_RPS="${LATENCY_RPS:-10000}"
LATENCY_DUR="${LATENCY_DUR:-60}"
WARMUP_DUR="${WARMUP_DUR:-10}"

FAIRVISOR_REMOTE="${FAIRVISOR_REMOTE:-}"
LOADGEN_REMOTE="${LOADGEN_REMOTE:-}"
FAIRVISOR_TARGET_HOST="${FAIRVISOR_TARGET_HOST:-}"
SSH_OPTS="${SSH_OPTS:-}"
DRY_RUN="${DRY_RUN:-0}"

# OpenResty binary — try PATH first, then default install locations.
ORESTY="$(command -v openresty 2>/dev/null \
    || ls /usr/local/openresty/bin/openresty 2>/dev/null \
    || ls /usr/local/openresty/nginx/sbin/nginx 2>/dev/null \
    || echo openresty)"

_NOFILE="$(ulimit -n 2>/dev/null || echo 1024)"
WORKER_CONN=$(( _NOFILE > 4096 ? 4096 : _NOFILE - 1 ))

TASKSET_BIN="$(command -v taskset 2>/dev/null || true)"
CPU_CORES="$(nproc 2>/dev/null || echo 1)"
ORESTY_CPUSET="${ORESTY_CPUSET:-}"
K6_CPUSET="${K6_CPUSET:-}"
if [[ -n "${TASKSET_BIN}" && "${CPU_CORES}" -ge 8 ]]; then
    : "${ORESTY_CPUSET:="0-$((CPU_CORES/2 - 1))"}"
    : "${K6_CPUSET:="$((CPU_CORES/2))-$((CPU_CORES - 1))"}"
fi

# Published targets (μs) — reference run: c7i.2xlarge, Ubuntu 24.04.3 LTS
declare -A TGT_D=([p50]=112  [p90]=191  [p99]=426  [p999]=2990)
declare -A TGT_P=([p50]=241  [p90]=376  [p99]=822  [p999]=2980)
declare -A TGT_N=([p50]=71   [p90]=190  [p99]=446  [p999]=1610)

# Published max RPS — reference run: c7i.2xlarge, Ubuntu 24.04.3 LTS
declare -A TGT_T=([simple]=110500 [complex]=67600 [llm]=49400)

# Measured results (filled in at runtime)
declare -A LAT_D LAT_P LAT_N
declare -A THR_RES
declare -a _BGPIDS=()

##############################################################################
# OUTPUT
##############################################################################
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
BLU='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'

log()    { echo -e "${BLU}[$(date +%H:%M:%S)]${RST} $*"; }
ok()     { echo -e "${GRN}✓${RST} $*"; }
warn()   { echo -e "${YLW}⚠${RST}  $*"; }
die()    { echo -e "${RED}✗ FATAL:${RST} $*" >&2; exit 1; }
banner() { echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n  $*\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"; }

##############################################################################
# REMOTE ORCHESTRATION HELPERS
##############################################################################
remote_mode_enabled() {
    [[ -n "${FAIRVISOR_REMOTE}" || -n "${LOADGEN_REMOTE}" ]]
}

infer_target_host() {
    local remote="$1"
    local stripped="${remote#*@}"
    stripped="${stripped%%:*}"
    echo "${stripped}"
}

require_remote_config() {
    [[ -n "${FAIRVISOR_REMOTE}" ]] || die "FAIRVISOR_REMOTE is required in remote mode"
    [[ -n "${LOADGEN_REMOTE}" ]] || die "LOADGEN_REMOTE is required in remote mode"
    if [[ -z "${FAIRVISOR_TARGET_HOST}" ]]; then
        FAIRVISOR_TARGET_HOST="$(infer_target_host "${FAIRVISOR_REMOTE}")"
    fi
}

_ssh() {
    if [[ "${DRY_RUN}" == "1" ]]; then
        printf 'DRY_RUN ssh %s %q\n' "$1" "$2"
        return 0
    fi
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "$1" "$2"
}

_scp_to() {
    if [[ "${DRY_RUN}" == "1" ]]; then
        printf 'DRY_RUN scp %q %s:%q\n' "$1" "$2" "$3"
        return 0
    fi
    # shellcheck disable=SC2086
    scp ${SSH_OPTS} "$1" "$2:$3"
}

_scp_from() {
    if [[ "${DRY_RUN}" == "1" ]]; then
        printf 'DRY_RUN scp %s:%q %q\n' "$1" "$2" "$3"
        return 0
    fi
    # shellcheck disable=SC2086
    scp ${SSH_OPTS} "$1:$2" "$3"
}

remote_run() {
    local host="$1"
    shift
    local cmd
    cmd=$(printf '%q ' "$@")
    _ssh "${host}" "cd ${BENCH_DIR} && ${cmd}"
}

remote_helper() {
    local host="$1"
    shift
    remote_run "${host}" env \
        BENCH_DIR="${BENCH_DIR}" \
        FV_DIR="${FV_DIR}" \
        K6_VER="${K6_VER}" \
        FV_PORT="${FV_PORT}" \
        BACKEND_PORT="${BACKEND_PORT}" \
        NGINX_PORT="${NGINX_PORT}" \
        LATENCY_RPS="${LATENCY_RPS}" \
        LATENCY_DUR="${LATENCY_DUR}" \
        WARMUP_DUR="${WARMUP_DUR}" \
        ORESTY_CPUSET="${ORESTY_CPUSET}" \
        K6_CPUSET="${K6_CPUSET}" \
        DRY_RUN="${DRY_RUN}" \
        bash "${BENCH_DIR}/run-all.sh" "$@"
}

sync_script_to_remote() {
    local host="$1"
    _ssh "${host}" "mkdir -p ${BENCH_DIR}"
    _scp_to "$0" "${host}" "${BENCH_DIR}/run-all.sh"
}

fetch_remote_file() {
    local host="$1" remote_path="$2" local_path="$3"
    mkdir -p "$(dirname "${local_path}")"
    _scp_from "${host}" "${remote_path}" "${local_path}"
}

##############################################################################
# PACKAGE INSTALLATION
##############################################################################
detect_os_id() {
    local os_id=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        os_id="${ID:-}"
    fi
    echo "${os_id}"
}

pkg_install() {
    local os_id="$1"; shift
    if [[ "$#" -eq 0 ]]; then
        return 0
    fi
    case "${os_id}" in
        ubuntu|debian)
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
            ;;
        amzn|rhel|centos|fedora)
            sudo dnf install -y "$@"
            ;;
        *)
            die "Unsupported OS '${os_id:-unknown}' for package installation"
            ;;
    esac
}

pkg_update_index() {
    local os_id="$1"
    case "${os_id}" in
        ubuntu|debian)
            sudo apt-get update -y
            ;;
        amzn|rhel|centos|fedora)
            :
            ;;
        *)
            die "Unsupported OS '${os_id:-unknown}' for package index update"
            ;;
    esac
}

ensure_common_tools() {
    local os_id="$1"
    local need=()
    command -v jq  &>/dev/null || need+=(jq)
    command -v bc  &>/dev/null || need+=(bc)
    command -v git &>/dev/null || need+=(git)
    command -v python3 &>/dev/null || need+=(python3)
    command -v pip3 &>/dev/null || need+=(python3-pip)
    if [[ ${#need[@]} -gt 0 ]]; then
        pkg_update_index "${os_id}"
        pkg_install "${os_id}" "${need[@]}"
    fi
    ok "jq bc git python3 pip3"
}

install_openresty_ubuntu() {
    local codename=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        codename="${VERSION_CODENAME:-}"
    fi
    if [[ -z "${codename}" ]]; then
        codename="$(lsb_release -cs 2>/dev/null || true)"
    fi
    [[ -z "${codename}" ]] && codename="jammy"

    pkg_update_index "ubuntu"
    pkg_install "ubuntu" ca-certificates curl gnupg lsb-release

    sudo mkdir -p /usr/share/keyrings
    curl -fsSL https://openresty.org/package/pubkey.gpg \
        | sudo gpg --dearmor -o /usr/share/keyrings/openresty.gpg

    echo "deb [signed-by=/usr/share/keyrings/openresty.gpg] https://openresty.org/package/ubuntu ${codename} main" \
        | sudo tee /etc/apt/sources.list.d/openresty.list >/dev/null

    if ! sudo apt-get update -y; then
        warn "OpenResty repo for '${codename}' failed — trying 'jammy' fallback"
        echo "deb [signed-by=/usr/share/keyrings/openresty.gpg] https://openresty.org/package/ubuntu jammy main" \
            | sudo tee /etc/apt/sources.list.d/openresty.list >/dev/null
        sudo apt-get update -y
    fi

    pkg_install "ubuntu" openresty gettext-base
}

ensure_openresty() {
    local os_id="$1"
    if command -v openresty &>/dev/null; then
        ok "OpenResty already present"
        return 0
    fi

    if [[ "${os_id}" == "ubuntu" || "${os_id}" == "debian" ]]; then
        log "Adding OpenResty repo (${os_id}) …"
        install_openresty_ubuntu
    else
        log "Adding OpenResty repo (Amazon Linux family) …"
        sudo tee /etc/yum.repos.d/openresty.repo >/dev/null <<'REPO'
[openresty]
name=Official OpenResty Open Source Repository for Amazon Linux 2023
baseurl=https://openresty.org/package/amazon/2023/$basearch
skip_if_unavailable=False
gpgcheck=1
repo_gpgcheck=0
gpgkey=https://openresty.org/package/pubkey.gpg
enabled=1
REPO
        if ! sudo dnf install -y openresty gettext 2>/dev/null; then
            warn "AL2023 repo failed — trying AL2 path …"
            sudo sed -i 's|/2023/|/2/|g' /etc/yum.repos.d/openresty.repo
            sudo dnf install -y openresty gettext
        fi
    fi
    ok "OpenResty $(openresty -v 2>&1 | grep -oE 'nginx/[0-9.]+' || true)"
}

ensure_k6() {
    if command -v k6 &>/dev/null; then
        ok "k6 already present"
        return 0
    fi

    log "Installing k6 ${K6_VER} …"
    curl -fsSL \
        "https://github.com/grafana/k6/releases/download/${K6_VER}/k6-${K6_VER}-linux-amd64.tar.gz" \
        | sudo tar xz -C /usr/local/bin --strip-components=1 \
            "k6-${K6_VER}-linux-amd64/k6"
    ok "k6 $(k6 version | head -1)"
}

install_loadgen_host() {
    banner "Installing load-generator dependencies"
    local os_id; os_id="$(detect_os_id)"
    ensure_common_tools "${os_id}"
    ensure_k6
}

install_fairvisor_host() {
    banner "Installing Fairvisor host dependencies"
    local os_id; os_id="$(detect_os_id)"
    ensure_common_tools "${os_id}"
    ensure_openresty "${os_id}"
    setup_fairvisor
    create_policies
}

##############################################################################
# 2. FAIRVISOR SETUP (no Docker)
##############################################################################
setup_fairvisor() {
    banner "Setting up Fairvisor"

    if [[ -d "${FV_DIR}/.git" ]]; then
        log "Updating existing clone …"
        sudo git -C "${FV_DIR}" pull --ff-only 2>/dev/null || true
    else
        log "Cloning github.com/fairvisor/edge → ${FV_DIR} …"
        sudo git clone --depth=1 https://github.com/fairvisor/edge "${FV_DIR}"
    fi

    for script in \
        "${FV_DIR}/bin/gen_asn_map.py" \
        "${FV_DIR}/data/generate_asn.py" \
        "${FV_DIR}/data/gen_asn.py"; do
        [[ -f "${script}" ]] && { log "Running $(basename "${script}") …"; sudo python3 "${script}" >/dev/null && break; }
    done || true

    for script in \
        "${FV_DIR}/bin/gen_tor_geo.py" \
        "${FV_DIR}/data/generate_tor.py" \
        "${FV_DIR}/data/gen_tor.py"; do
        [[ -f "${script}" ]] && { log "Running $(basename "${script}") …"; sudo python3 "${script}" >/dev/null && break; }
    done || true

    [[ -f "${FV_DIR}/requirements.txt" ]] \
        && sudo pip3 install -q -r "${FV_DIR}/requirements.txt" \
        || true

    for script in \
        "${FV_DIR}/bin/gen_asn_map.py"  "${FV_DIR}/data/generate_asn.py" \
        "${FV_DIR}/bin/gen_tor_geo.py"  "${FV_DIR}/data/generate_tor.py"; do
        [[ -f "${script}" ]] && sudo python3 "${script}" 2>/dev/null || true
    done

    sudo mkdir -p /etc/fairvisor /etc/nginx/iplists

    local asn_src
    for asn_src in \
        "${FV_DIR}/asn_type.map" \
        "${FV_DIR}/data/asn_type.map"; do
        [[ -f "${asn_src}" ]] && { sudo cp "${asn_src}" /etc/fairvisor/asn_type.map; break; }
    done
    [[ ! -f /etc/fairvisor/asn_type.map ]] && sudo touch /etc/fairvisor/asn_type.map
    [[ ! -f /etc/nginx/iplists/tor_exits.geo ]] && sudo touch /etc/nginx/iplists/tor_exits.geo

    warn "Tor/ASN stubs created (geo lookups disabled for benchmarking)"
    ok "Fairvisor ready at ${FV_DIR}"
}

##############################################################################
# 3. POLICY FILES
##############################################################################
JWT_SECRET="bench-hs256-key-NOT-for-production"

gen_jwt() {
    local h; h=$(printf '{"alg":"HS256","typ":"JWT"}' | base64 -w0 | tr '+/' '-_' | tr -d '=')
    local p; p=$(printf '{"sub":"bench-user","org_id":"bench-org","iat":1700000000,"exp":9999999999}' \
        | base64 -w0 | tr '+/' '-_' | tr -d '=')
    local sig; sig=$(printf '%s' "${h}.${p}" \
        | openssl dgst -sha256 -hmac "${JWT_SECRET}" -binary \
        | base64 -w0 | tr '+/' '-_' | tr -d '=')
    printf '%s.%s.%s' "${h}" "${p}" "${sig}"
}

create_policies() {
    local pd="${BENCH_DIR}/policies"
    mkdir -p "${pd}"

    cat > "${pd}/simple.json" <<'EOF'
{
  "bundle_version": 1,
  "issued_at": "2026-01-01T00:00:00Z",
  "expires_at": "2030-01-01T00:00:00Z",
  "policies": [{
    "id": "bench-simple",
    "spec": {
      "selector": { "pathPrefix": "/", "methods": ["GET","POST"] },
      "mode": "enforce",
      "rules": [{
        "name": "ip-rps",
        "limit_keys": ["ip:address"],
        "algorithm": "token_bucket",
        "algorithm_config": { "tokens_per_second": 99999999, "burst": 99999999 }
      }]
    }
  }],
  "kill_switches": []
}
EOF

    cat > "${pd}/complex.json" <<EOF
{
  "bundle_version": 1,
  "issued_at": "2026-01-01T00:00:00Z",
  "expires_at": "2030-01-01T00:00:00Z",
  "jwt_keys": [{ "id": "bench", "algorithm": "HS256", "secret": "${JWT_SECRET}" }],
  "policies": [{
    "id": "bench-complex",
    "spec": {
      "selector": { "pathPrefix": "/", "methods": ["GET","POST"] },
      "mode": "enforce",
      "rules": [
        {
          "name": "ip-rate",
          "limit_keys": ["ip:address"],
          "algorithm": "token_bucket",
          "algorithm_config": { "tokens_per_second": 99999999, "burst": 99999999 }
        },
        {
          "name": "org-quota",
          "limit_keys": ["jwt:org_id"],
          "algorithm": "token_bucket",
          "algorithm_config": { "tokens_per_second": 99999999, "burst": 99999999 }
        },
        {
          "name": "user-rate",
          "limit_keys": ["jwt:sub"],
          "algorithm": "token_bucket",
          "algorithm_config": { "tokens_per_second": 99999999, "burst": 99999999 }
        },
        {
          "name": "loop-detect",
          "algorithm": "loop_detection",
          "algorithm_config": {
            "enabled": true,
            "window_seconds": 60,
            "threshold_identical_requests": 99999999,
            "action": "allow",
            "similarity": "exact"
          }
        },
        {
          "name": "circuit",
          "limit_keys": ["jwt:org_id"],
          "algorithm": "circuit_breaker",
          "algorithm_config": { "error_threshold": 0.999, "window_seconds": 60 }
        }
      ]
    }
  }],
  "kill_switches": []
}
EOF

    cat > "${pd}/llm.json" <<EOF
{
  "bundle_version": 1,
  "issued_at": "2026-01-01T00:00:00Z",
  "expires_at": "2030-01-01T00:00:00Z",
  "jwt_keys": [{ "id": "bench", "algorithm": "HS256", "secret": "${JWT_SECRET}" }],
  "policies": [{
    "id": "bench-llm",
    "spec": {
      "selector": { "pathPrefix": "/", "methods": ["GET","POST"] },
      "mode": "enforce",
      "rules": [{
        "name": "org-tpm",
        "limit_keys": ["jwt:org_id"],
        "algorithm": "token_bucket_llm",
        "algorithm_config": {
          "algorithm": "token_bucket_llm",
          "tokens_per_minute": 99999999999,
          "tokens_per_day": 99999999999999,
          "burst_tokens": 99999999999,
          "default_max_completion": 1024,
          "token_source": { "estimator": "simple_word" },
          "_tpm_bucket_config": {
            "tokens_per_second": 1666666666.65,
            "burst": 99999999999
          }
        }
      }]
    }
  }],
  "kill_switches": []
}
EOF

    ok "Policies: simple  complex  llm"
}

##############################################################################
# 4. SERVICE MANAGEMENT
##############################################################################
run_oresty_bg() {
    if [[ -n "${TASKSET_BIN}" && -n "${ORESTY_CPUSET}" ]]; then
        taskset -c "${ORESTY_CPUSET}" "${ORESTY}" "$@" &
    else
        "${ORESTY}" "$@" &
    fi
    _BGPIDS+=($!)
}

k6_run() {
    if [[ -n "${TASKSET_BIN}" && -n "${K6_CPUSET}" ]]; then
        taskset -c "${K6_CPUSET}" k6 "$@"
    else
        k6 "$@"
    fi
}

_cleanup() {
    for pid in "${_BGPIDS[@]:-}"; do
        kill "${pid}" 2>/dev/null || true
    done
    _BGPIDS=()
}
trap '_cleanup' EXIT INT TERM

_wait_port() {
    local port="$1"
    local n=80
    while ! bash -c "echo >/dev/tcp/127.0.0.1/${port}" 2>/dev/null; do
        sleep 0.3
        (( n-- ))
        [[ $n -le 0 ]] && return 1
    done
    sleep 0.2
    curl -sf "http://127.0.0.1:${port}/livez" >/dev/null 2>&1 || \
    curl -sf "http://127.0.0.1:${port}/" >/dev/null 2>&1 || true
    return 0
}

stop_all() {
    _cleanup
    sleep 1
}

start_baseline() {
    local pfx="${BENCH_DIR}/run/baseline"
    mkdir -p "${pfx}/logs" "${pfx}/tmp" "${pfx}/conf"
    cat > "${pfx}/conf/nginx.conf" <<EOF
worker_processes auto;
error_log ${pfx}/logs/error.log warn;
pid       ${pfx}/tmp/nginx.pid;
events { worker_connections ${WORKER_CONN}; use epoll; multi_accept on; }
http {
  access_log off;
  keepalive_timeout 65;
  keepalive_requests 100000;
  server {
    listen ${NGINX_PORT};
    location /livez { return 200 'ok\n'; add_header Content-Type text/plain; }
    location /     { return 200 'ok\n'; add_header Content-Type text/plain; }
  }
}
EOF
    run_oresty_bg -p "${pfx}" -c "${pfx}/conf/nginx.conf" -g 'daemon off;' \
        >"${pfx}/logs/stdout.log" 2>"${pfx}/logs/stderr.log"
    _wait_port "${NGINX_PORT}" || {
        warn "baseline nginx stderr:"; cat "${pfx}/logs/stderr.log" >&2
        die "baseline nginx failed to start"
    }
    ok "Baseline nginx  :${NGINX_PORT}"
}

start_backend() {
    local pfx="${BENCH_DIR}/run/backend"
    mkdir -p "${pfx}/logs" "${pfx}/tmp" "${pfx}/conf"
    cat > "${pfx}/conf/nginx.conf" <<EOF
worker_processes auto;
error_log ${pfx}/logs/error.log warn;
pid       ${pfx}/tmp/nginx.pid;
events { worker_connections ${WORKER_CONN}; use epoll; multi_accept on; }
http {
  access_log off;
  keepalive_timeout 65;
  keepalive_requests 100000;
  server {
    listen ${BACKEND_PORT};
    location /livez { return 200 'ok\n'; add_header Content-Type text/plain; }
    location / {
      return 200 '{"id":"chatcmpl-bench","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":1,"total_tokens":11}}\n';
      add_header Content-Type application/json;
    }
  }
}
EOF
    run_oresty_bg -p "${pfx}" -c "${pfx}/conf/nginx.conf" -g 'daemon off;' \
        >"${pfx}/logs/stdout.log" 2>"${pfx}/logs/stderr.log"
    _wait_port "${BACKEND_PORT}" || {
        warn "backend nginx stderr:"; cat "${pfx}/logs/stderr.log" >&2
        die "backend nginx failed to start"
    }
    ok "Backend nginx    :${BACKEND_PORT}"
}

start_fairvisor() {
    local mode="$1"
    local policy="$2"
    local pfx="${BENCH_DIR}/run/fv"
    mkdir -p "${pfx}/logs" "${pfx}/tmp" "${pfx}/conf"

    export FAIRVISOR_MODE="${mode}"
    export FAIRVISOR_CONFIG_FILE="${policy}"
    export FAIRVISOR_BACKEND_URL="http://127.0.0.1:${BACKEND_PORT}"
    export FAIRVISOR_SHARED_DICT_SIZE="256m"
    export FAIRVISOR_LOG_LEVEL="warn"
    export FAIRVISOR_WORKER_PROCESSES="auto"

    envsubst \
        '${FAIRVISOR_SHARED_DICT_SIZE} ${FAIRVISOR_LOG_LEVEL} ${FAIRVISOR_MODE} ${FAIRVISOR_BACKEND_URL} ${FAIRVISOR_WORKER_PROCESSES}' \
        < "${FV_DIR}/docker/nginx.conf.template" \
        > "${pfx}/conf/nginx.conf"

    sed -i \
        -e "s|/usr/local/openresty/nginx/logs/|${pfx}/logs/|g" \
        -e "s|/usr/local/openresty/nginx/tmp/|${pfx}/tmp/|g" \
        -e "s|pid /tmp/nginx\.pid|pid ${pfx}/tmp/nginx.pid|g" \
        -e "s|listen 8080 |listen ${FV_PORT} |g" \
        -e "s|listen 8080;|listen ${FV_PORT};|g" \
        "${pfx}/conf/nginx.conf"

    local _attempt
    for _attempt in 1 2 3; do
        local _test_err
        _test_err=$(${ORESTY} -t -p "${pfx}" -c "${pfx}/conf/nginx.conf" 2>&1 || true)
        if echo "${_test_err}" | grep -q 'test is successful\|configuration file.*test is successful'; then
            break
        fi
        local _missing
        _missing=$(echo "${_test_err}" | grep -oP 'open\(\) "\K[^"]+(?=" failed \(2)' | head -1)
        if [[ -n "${_missing}" ]]; then
            warn "Creating stub for missing include: ${_missing}"
            sudo mkdir -p "$(dirname "${_missing}")"
            sudo touch "${_missing}"
        else
            warn "nginx -t failed:"
            echo "${_test_err}" >&2
            die "Aborting — unrecoverable nginx config error."
        fi
    done

    FAIRVISOR_CONFIG_FILE="${policy}" \
    run_oresty_bg -p "${pfx}" -c "${pfx}/conf/nginx.conf" -g 'daemon off;' \
        >"${pfx}/logs/stdout.log" 2>"${pfx}/logs/stderr.log"

    _wait_port "${FV_PORT}" || {
        warn "Fairvisor failed to start. Last stderr:"
        tail -30 "${pfx}/logs/stderr.log" >&2
        die "Aborting."
    }
    ok "Fairvisor [${mode}]  :${FV_PORT}  policy=$(basename "${policy}")"
}

##############################################################################
# 5. k6 SCRIPTS
##############################################################################
_k6_dir() { mkdir -p "${BENCH_DIR}/scripts"; echo "${BENCH_DIR}/scripts"; }

write_latency_js() {
    local name="$1" url="$2" rps="$3" dur="$4" jwt="$5" mode="$6"
    local f; f="$(_k6_dir)/${name}.js"
    cat > "${f}" <<EOF
import http from 'k6/http';
import { check } from 'k6';
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.0.2/index.js';

export const options = {
  scenarios: {
    steady: {
      executor: 'constant-arrival-rate',
      rate: ${rps},
      timeUnit: '1s',
      duration: '${dur}s',
      preAllocatedVUs: 200,
      maxVUs: 500,
    },
  },
  summaryTrendStats: ['p(50)','p(90)','p(99)','p(99.9)','max'],
};

const URL = '${url}';
const JWT = '${jwt}';
const MODE = '${mode}';

export default function () {
  const headers = { 'Content-Type': 'application/json' };
  if (JWT) headers['Authorization'] = 'Bearer ' + JWT;
  let res;
  if (MODE === 'decision') {
    headers['X-Forwarded-For'] = \`203.0.113.\${(__VU % 254) + 1}\`;
    headers['X-Original-Method'] = 'POST';
    headers['X-Original-URI'] = '/v1/chat/completions';
    res = http.post(URL, '{}', { headers });
  } else {
    res = http.get(URL, { headers });
  }
  check(res, { '2xx/204': r => (r.status >= 200 && r.status < 300) || r.status === 204 });
}

export function handleSummary(data) {
  const outFile = __ENV.SUMMARY_OUT || '/tmp/k6_last_summary.json';
  return {
    stdout: textSummary(data, { indent: ' ', enableColors: true }),
    [outFile]: JSON.stringify(data),
  };
}
EOF
    echo "${f}"
}

write_warmup_js() {
    local name="$1" url="$2" jwt="$3"
    local f; f="$(_k6_dir)/${name}_warmup.js"
    cat > "${f}" <<EOF
import http from 'k6/http';
export const options = { vus: 50, duration: '${WARMUP_DUR}s' };
const URL = '${url}';
const JWT = '${jwt}';
export default function () {
  http.get(URL, JWT ? { headers: { 'Authorization': 'Bearer ' + JWT } } : {});
}
EOF
    echo "${f}"
}

write_step_js() {
    local name="$1" url="$2" rps="$3" jwt="$4" body="$5"
    local f; f="$(_k6_dir)/${name}.js"
    cat > "${f}" <<EOF
import http from 'k6/http';
import { check } from 'k6';

export const options = {
  scenarios: {
    step: {
      executor: 'constant-arrival-rate',
      rate: ${rps},
      timeUnit: '1s',
      duration: '20s',
      preAllocatedVUs: 600,
      maxVUs: 2500,
    },
  },
  summaryTrendStats: ['p(50)','p(99)'],
};

const URL = '${url}';
const JWT = '${jwt}';
const BODY = \`${body}\`;

export default function () {
  const headers = { 'Content-Type': 'application/json' };
  if (JWT) headers['Authorization'] = 'Bearer ' + JWT;
  headers['X-Request-Id'] = \`\${__VU}-\${__ITER}\`;
  const res = BODY
    ? http.post(URL, BODY, { headers })
    : http.get(URL, { headers });
  check(res, { '2xx': r => r.status >= 200 && r.status < 300 });
}

export function handleSummary(data) {
  const outFile = __ENV.SUMMARY_OUT || '/tmp/k6_last_summary.json';
  return { [outFile]: JSON.stringify(data) };
}
EOF
    echo "${f}"
}

##############################################################################
# 6. LOCAL RESULT PARSING
##############################################################################
_parse_latency() {
    local file="$1" dst="$2"
    if [[ ! -s "${file}" ]]; then
        warn "_parse_latency: ${file} is empty or missing — skipping"
        return 0
    fi

    local p50 p90 p99 p999
    p50=$(jq -r '(.metrics.http_req_duration.values // .metrics.http_req_waiting.values) | (.["p(50)"] // .med // 0)' "${file}")
    p90=$(jq -r '(.metrics.http_req_duration.values // .metrics.http_req_waiting.values) | (.["p(90)"] // 0)' "${file}")
    p99=$(jq -r '(.metrics.http_req_duration.values // .metrics.http_req_waiting.values) | (.["p(99)"] // 0)' "${file}")
    p999=$(jq -r '(.metrics.http_req_duration.values // .metrics.http_req_waiting.values) | (.["p(99.9)"] // 0)' "${file}")

    eval "${dst}[p50]=$(printf '%.0f' "$(echo "${p50} * 1000" | bc -l)")"
    eval "${dst}[p90]=$(printf '%.0f' "$(echo "${p90} * 1000" | bc -l)")"
    eval "${dst}[p99]=$(printf '%.0f' "$(echo "${p99} * 1000" | bc -l)")"
    eval "${dst}[p999]=$(printf '%.0f' "$(echo "${p999} * 1000" | bc -l)")"
}

parse_throughput_result() {
    local label="$1" file="$2"
    if [[ ! -s "${file}" ]]; then
        warn "throughput summary missing: ${file}"
        THR_RES["${label}"]=0
        return 0
    fi

    local err_rate p99_ms rps
    err_rate=$(jq '.metrics.http_req_failed.values.rate // 1' "${file}" 2>/dev/null || echo 1)
    p99_ms=$(jq '(.metrics.http_req_duration.values // .metrics.http_req_waiting.values) | (.["p(99)"] // 9999)' "${file}" 2>/dev/null || echo 9999)
    rps=$(jq '.metrics.http_reqs.values.rate // 0' "${file}" 2>/dev/null || echo 0)

    local pass_err pass_p99
    pass_err=$(echo "${err_rate} < 0.01" | bc -l)
    pass_p99=$(echo "${p99_ms} < 1000" | bc -l)

    if [[ "${pass_err}" == "1" && "${pass_p99}" == "1" ]]; then
        THR_RES["${label}"]=$(printf '%.0f' "${rps}")
    else
        THR_RES["${label}"]=0
    fi
}

##############################################################################
# 7. REMOTE HELPER COMMANDS
##############################################################################
helper_install() {
    local role="$1"
    mkdir -p "${BENCH_DIR}/results" "${BENCH_DIR}/scripts"
    case "${role}" in
        fairvisor) install_fairvisor_host ;;
        loadgen) install_loadgen_host ;;
        *) die "Unknown helper-install role: ${role}" ;;
    esac
}

helper_start() {
    local what="$1"
    mkdir -p "${BENCH_DIR}/results" "${BENCH_DIR}/scripts"
    case "${what}" in
        baseline)
            pkill -f "openresty" 2>/dev/null || true
            sleep 1
            start_baseline
            ;;
        backend)
            pkill -f "openresty" 2>/dev/null || true
            sleep 1
            start_backend
            ;;
        *)
            die "Unknown helper-start target: ${what}"
            ;;
    esac
}

helper_start_fairvisor() {
    local mode="$1" policy_name="$2"
    pkill -f "openresty" 2>/dev/null || true
    sleep 1
    if [[ "${mode}" == "reverse_proxy" ]]; then
        start_backend
    fi
    start_fairvisor "${mode}" "${BENCH_DIR}/policies/${policy_name}"
}

helper_stop_all() {
    stop_all
    pkill -f "openresty" 2>/dev/null || true
}

helper_run_latency() {
    local label="$1" url="$2" jwt="$3" mode="$4"
    mkdir -p "${BENCH_DIR}/results" "${BENCH_DIR}/scripts"
    local script warmup out
    script=$(write_latency_js "lat_${label}" "${url}" "${LATENCY_RPS}" "${LATENCY_DUR}" "${jwt}" "${mode}")
    warmup=$(write_warmup_js "lat_${label}" "${url}" "${jwt}")
    out="${BENCH_DIR}/results/lat_${label}.json"

    log "Warmup ${label} (${WARMUP_DUR}s) …"
    k6_run run --quiet --no-summary "${warmup}" >/dev/null 2>&1 || true

    log "Latency test: ${label} @ ${LATENCY_RPS} RPS for ${LATENCY_DUR}s …"
    k6_run run -e "SUMMARY_OUT=${out}" "${script}" 2>&1 | tail -18 || true
}

helper_run_throughput() {
    local label="$1" url="$2" jwt="$3" body="$4" target="$5"
    mkdir -p "${BENCH_DIR}/results" "${BENCH_DIR}/scripts"

    for pct in 50 70 90 100 115 130; do
        local rps step_name step_out js
        rps=$(( target * pct / 100 ))
        step_name="thr_${label}_${pct}"
        step_out="${BENCH_DIR}/results/${step_name}.json"
        js=$(write_step_js "${step_name}" "${url}" "${rps}" "${jwt}" "${body}")
        log "  → step ${pct}% (${rps} RPS, 20s) …"
        k6_run run --quiet -e "SUMMARY_OUT=${step_out}" "${js}" >/dev/null 2>&1 || true
    done
}

##############################################################################
# 8. CONTROLLER FLOW
##############################################################################
controller_prepare() {
    require_remote_config
    mkdir -p "${BENCH_DIR}/controller-results"

    log "Syncing orchestration script to remote hosts"
    sync_script_to_remote "${FAIRVISOR_REMOTE}"
    sync_script_to_remote "${LOADGEN_REMOTE}"

    banner "Preparing remote Fairvisor host"
    remote_helper "${FAIRVISOR_REMOTE}" helper-install fairvisor

    banner "Preparing remote load-generator host"
    remote_helper "${LOADGEN_REMOTE}" helper-install loadgen
}

controller_fetch_latency() {
    local label="$1" dst="$2"
    local local_file="${BENCH_DIR}/controller-results/lat_${label}.json"
    fetch_remote_file "${LOADGEN_REMOTE}" "${BENCH_DIR}/results/lat_${label}.json" "${local_file}"
    _parse_latency "${local_file}" "${dst}"
}

controller_fetch_best_throughput() {
    local label="$1" target="$2"
    if [[ "${DRY_RUN}" == "1" ]]; then
        warn "Skipping throughput result parsing in DRY_RUN for ${label}"
        THR_RES["${label}"]="N/A"
        return 0
    fi
    local best=0
    local pct

    for pct in 50 70 90 100 115 130; do
        local local_file="${BENCH_DIR}/controller-results/thr_${label}_${pct}.json"
        fetch_remote_file "${LOADGEN_REMOTE}" "${BENCH_DIR}/results/thr_${label}_${pct}.json" "${local_file}"

        local err_rate p99_ms
        err_rate=$(jq '.metrics.http_req_failed.values.rate // 1' "${local_file}" 2>/dev/null || echo 1)
        p99_ms=$(jq '(.metrics.http_req_duration.values // .metrics.http_req_waiting.values) | (.["p(99)"] // 9999)' "${local_file}" 2>/dev/null || echo 9999)

        local pass_err pass_p99 current
        pass_err=$(echo "${err_rate} < 0.01" | bc -l)
        pass_p99=$(echo "${p99_ms} < 1000" | bc -l)
        current=$(( target * pct / 100 ))

        if [[ "${pass_err}" == "1" && "${pass_p99}" == "1" ]]; then
            best="${current}"
            ok "    PASS @ ${current} RPS  (err=$(printf '%.2f%%' "$(echo "${err_rate}*100" | bc -l)")  p99=$(printf '%.0fms' "${p99_ms}"))"
        else
            warn "    FAIL @ ${current} RPS  (err=$(printf '%.2f%%' "$(echo "${err_rate}*100" | bc -l)")  p99=$(printf '%.0fms' "${p99_ms}")) — stopping"
            break
        fi
    done

    THR_RES["${label}"]="${best}"
    ok "${label}: max sustained ≈ ${best} RPS"
}

controller_benchmark() {
    local jwt pd fv_url nginx_url decision_url llm_body
    jwt="$(gen_jwt)"
    pd="${BENCH_DIR}/policies"
    fv_url="http://${FAIRVISOR_TARGET_HOST}:${FV_PORT}"
    nginx_url="http://${FAIRVISOR_TARGET_HOST}:${NGINX_PORT}"
    decision_url="${fv_url}/v1/decision"
    llm_body='{"model":"gpt-4o","messages":[{"role":"user","content":"Hello, this is a benchmark test message for token estimation."}]}'

    banner "TEST 1/6 — Raw nginx baseline (latency)"
    remote_helper "${FAIRVISOR_REMOTE}" helper-stop-all
    remote_helper "${FAIRVISOR_REMOTE}" helper-start baseline
    remote_helper "${LOADGEN_REMOTE}" helper-run-latency nginx "${nginx_url}/" "" get
    controller_fetch_latency "nginx" "LAT_N"
    remote_helper "${FAIRVISOR_REMOTE}" helper-stop-all

    banner "TEST 2/6 — Fairvisor decision_service (latency)"
    remote_helper "${FAIRVISOR_REMOTE}" helper-stop-all
    remote_helper "${FAIRVISOR_REMOTE}" helper-start-fairvisor decision_service simple.json
    remote_helper "${LOADGEN_REMOTE}" helper-run-latency decision "${decision_url}" "${jwt}" decision
    controller_fetch_latency "decision" "LAT_D"
    remote_helper "${FAIRVISOR_REMOTE}" helper-stop-all

    banner "TEST 3/6 — Fairvisor reverse_proxy (latency)"
    remote_helper "${FAIRVISOR_REMOTE}" helper-stop-all
    remote_helper "${FAIRVISOR_REMOTE}" helper-start-fairvisor reverse_proxy simple.json
    remote_helper "${LOADGEN_REMOTE}" helper-run-latency proxy "${fv_url}/" "${jwt}" get
    controller_fetch_latency "proxy" "LAT_P"
    remote_helper "${FAIRVISOR_REMOTE}" helper-stop-all

    banner "TEST 4/6 — Max throughput: simple rate limit (1 rule)"
    remote_helper "${FAIRVISOR_REMOTE}" helper-stop-all
    remote_helper "${FAIRVISOR_REMOTE}" helper-start-fairvisor reverse_proxy simple.json
    remote_helper "${LOADGEN_REMOTE}" helper-run-throughput simple "${fv_url}/" "" "" "${TGT_T[simple]}"
    controller_fetch_best_throughput "simple" "${TGT_T[simple]}"
    remote_helper "${FAIRVISOR_REMOTE}" helper-stop-all

    banner "TEST 5/6 — Max throughput: complex policy (5 rules + JWT + loop)"
    remote_helper "${FAIRVISOR_REMOTE}" helper-stop-all
    remote_helper "${FAIRVISOR_REMOTE}" helper-start-fairvisor reverse_proxy complex.json
    remote_helper "${LOADGEN_REMOTE}" helper-run-throughput complex "${fv_url}/" "${jwt}" "" "${TGT_T[complex]}"
    controller_fetch_best_throughput "complex" "${TGT_T[complex]}"
    remote_helper "${FAIRVISOR_REMOTE}" helper-stop-all

    banner "TEST 6/6 — Max throughput: token estimation (tiktoken)"
    remote_helper "${FAIRVISOR_REMOTE}" helper-stop-all
    remote_helper "${FAIRVISOR_REMOTE}" helper-start-fairvisor reverse_proxy llm.json
    remote_helper "${LOADGEN_REMOTE}" helper-run-throughput llm "${fv_url}/" "${jwt}" "${llm_body}" "${TGT_T[llm]}"
    controller_fetch_best_throughput "llm" "${TGT_T[llm]}"
    remote_helper "${FAIRVISOR_REMOTE}" helper-stop-all
}

controller_main() {
    if [[ "${DRY_RUN}" == "1" ]]; then
        require_remote_config
        controller_prepare
        controller_benchmark || true
        ok "Dry-run completed for remote controller flow"
        return 0
    fi

    controller_prepare
    controller_benchmark
    print_results "controller"
}

##############################################################################
# 9. LOCAL SINGLE-HOST FLOW
##############################################################################
local_single_host_main() {
    mkdir -p "${BENCH_DIR}/results" "${BENCH_DIR}/scripts"

    if [[ -n "${TASKSET_BIN}" ]]; then
        log "CPU pinning: openresty='${ORESTY_CPUSET:-auto/off}'  k6='${K6_CPUSET:-auto/off}'"
    else
        warn "taskset not found — CPU pinning disabled"
    fi

    pkill -f "openresty" 2>/dev/null || true
    sleep 1

    install_loadgen_host
    local os_id; os_id="$(detect_os_id)"
    ensure_openresty "${os_id}"
    setup_fairvisor
    create_policies

    local jwt pd fv_url nginx_url decision_url llm_body s_lat s_warmup
    jwt="$(gen_jwt)"
    pd="${BENCH_DIR}/policies"
    fv_url="http://127.0.0.1:${FV_PORT}"
    nginx_url="http://127.0.0.1:${NGINX_PORT}"
    decision_url="${fv_url}/v1/decision"
    llm_body='{"model":"gpt-4o","messages":[{"role":"user","content":"Hello, this is a benchmark test message for token estimation."}]}'

    banner "TEST 1/6 — Raw nginx baseline (latency)"
    start_baseline
    s_lat=$(write_latency_js "lat_nginx" "${nginx_url}/" "${LATENCY_RPS}" "${LATENCY_DUR}" "" get)
    s_warmup=$(write_warmup_js "lat_nginx" "${nginx_url}/" "")
    helper_run_latency nginx "${nginx_url}/" "" get >/dev/null 2>&1 || true
    _parse_latency "${BENCH_DIR}/results/lat_nginx.json" "LAT_N"
    stop_all

    banner "TEST 2/6 — Fairvisor decision_service (latency)"
    start_fairvisor decision_service "${pd}/simple.json"
    helper_run_latency decision "${decision_url}" "${jwt}" decision >/dev/null 2>&1 || true
    _parse_latency "${BENCH_DIR}/results/lat_decision.json" "LAT_D"
    stop_all

    banner "TEST 3/6 — Fairvisor reverse_proxy (latency)"
    start_backend
    start_fairvisor reverse_proxy "${pd}/simple.json"
    helper_run_latency proxy "${fv_url}/" "${jwt}" get >/dev/null 2>&1 || true
    _parse_latency "${BENCH_DIR}/results/lat_proxy.json" "LAT_P"
    stop_all

    banner "TEST 4/6 — Max throughput: simple rate limit (1 rule)"
    start_backend
    start_fairvisor reverse_proxy "${pd}/simple.json"
    helper_run_throughput simple "${fv_url}/" "" "" "${TGT_T[simple]}"
    controller_fetch_best_throughput_local simple "${TGT_T[simple]}"
    stop_all

    banner "TEST 5/6 — Max throughput: complex policy (5 rules + JWT + loop)"
    start_backend
    start_fairvisor reverse_proxy "${pd}/complex.json"
    helper_run_throughput complex "${fv_url}/" "${jwt}" "" "${TGT_T[complex]}"
    controller_fetch_best_throughput_local complex "${TGT_T[complex]}"
    stop_all

    banner "TEST 6/6 — Max throughput: token estimation (tiktoken)"
    start_backend
    start_fairvisor reverse_proxy "${pd}/llm.json"
    helper_run_throughput llm "${fv_url}/" "${jwt}" "${llm_body}" "${TGT_T[llm]}"
    controller_fetch_best_throughput_local llm "${TGT_T[llm]}"
    stop_all

    print_results "single-host"
}

controller_fetch_best_throughput_local() {
    local label="$1" target="$2"
    local best=0 pct

    for pct in 50 70 90 100 115 130; do
        local file="${BENCH_DIR}/results/thr_${label}_${pct}.json"
        local err_rate p99_ms current
        err_rate=$(jq '.metrics.http_req_failed.values.rate // 1' "${file}" 2>/dev/null || echo 1)
        p99_ms=$(jq '(.metrics.http_req_duration.values // .metrics.http_req_waiting.values) | (.["p(99)"] // 9999)' "${file}" 2>/dev/null || echo 9999)
        current=$(( target * pct / 100 ))
        if [[ "$(echo "${err_rate} < 0.01" | bc -l)" == "1" && "$(echo "${p99_ms} < 1000" | bc -l)" == "1" ]]; then
            best="${current}"
        else
            break
        fi
    done
    THR_RES["${label}"]="${best}"
    ok "${label}: max sustained ≈ ${best} RPS"
}

##############################################################################
# 10. RESULTS TABLE
##############################################################################
_us() {
    local v="$1"
    if (( v >= 1000 )); then
        printf "%.2f ms" "$(echo "scale=4; ${v}/1000" | bc)"
    else
        printf "%d μs" "${v}"
    fi
}

_col_lat() {
    local got="$1" tgt="$2"
    [[ "${got}" == "N/A" ]] && echo "${YLW}" && return
    local ok110 ok130
    ok110=$(printf '%.0f' "$(echo "${tgt}*1.10" | bc -l)")
    ok130=$(printf '%.0f' "$(echo "${tgt}*1.30" | bc -l)")
    (( got <= ok110 )) && echo "${GRN}" && return
    (( got <= ok130 )) && echo "${YLW}" && return
    echo "${RED}"
}

_col_thr() {
    local got="$1" tgt="$2"
    [[ "${got}" == "N/A" || "${got}" == "0" ]] && echo "${YLW}" && return
    local ok90
    ok90=$(printf '%.0f' "$(echo "${tgt}*0.90" | bc -l)")
    (( got >= ok90 )) && echo "${GRN}" || echo "${RED}"
}

print_results() {
    local mode_label="${1:-single-host}"
    local w=82 hr hr2
    hr=$(printf '═%.0s' $(seq 1 $w))
    hr2=$(printf '─%.0s' $(seq 1 $w))

    echo ""
    echo -e "${BOLD}${hr}${RST}"
    echo -e "${BOLD}  FAIRVISOR BENCHMARK RESULTS (${mode_label})${RST}"
    echo -e "${BOLD}${hr}${RST}"

    echo ""
    echo -e "${BOLD}  Latency @ ${LATENCY_RPS} RPS steady state${RST}  ${DIM}(target: fairvisor/edge README)${RST}"
    echo ""
    printf "  ${BOLD}%-8s  %-26s  %-26s  %-20s${RST}\n" \
        "Pct" "Decision Service" "Reverse Proxy" "Raw nginx"
    printf "  %-8s  %-26s  %-26s  %-20s\n" \
        "────────" "${hr2:0:24}" "${hr2:0:24}" "${hr2:0:18}"

    local rows=("p50:p50:112:241:71" "p90:p90:191:376:190" "p99:p99:426:822:446" "p99.9:p999:2990:2980:1610")
    local row
    for row in "${rows[@]}"; do
        IFS=: read -r lbl key td tp tn <<< "${row}"

        local gd gp gn fd fp fn cd cp cn
        eval "gd=\${LAT_D[${key}]:-N/A}"
        eval "gp=\${LAT_P[${key}]:-N/A}"
        eval "gn=\${LAT_N[${key}]:-N/A}"

        [[ "${gd}" == "N/A" ]] && fd="N/A (tgt: $(_us "$td"))" || fd="$(_us "$gd") (tgt: $(_us "$td"))"
        [[ "${gp}" == "N/A" ]] && fp="N/A (tgt: $(_us "$tp"))" || fp="$(_us "$gp") (tgt: $(_us "$tp"))"
        [[ "${gn}" == "N/A" ]] && fn="N/A (tgt: $(_us "$tn"))" || fn="$(_us "$gn") (tgt: $(_us "$tn"))"

        [[ "${gd}" == "N/A" ]] && cd="${YLW}" || cd=$(_col_lat "${gd}" "${td}")
        [[ "${gp}" == "N/A" ]] && cp="${YLW}" || cp=$(_col_lat "${gp}" "${tp}")
        [[ "${gn}" == "N/A" ]] && cn="${YLW}" || cn=$(_col_lat "${gn}" "${tn}")

        printf "  %-8s  ${cd}%-26s${RST}  ${cp}%-26s${RST}  ${cn}%-20s${RST}\n" \
            "${lbl}" "${fd}" "${fp}" "${fn}"
    done

    echo ""
    echo -e "${BOLD}  Max Sustained Throughput — single fairvisor instance${RST}"
    echo ""
    printf "  ${BOLD}%-48s  %-14s  %-14s${RST}\n" "Configuration" "Measured RPS" "Target RPS"
    printf "  %-48s  %-14s  %-14s\n" "${hr2:0:48}" "──────────────" "──────────────"

    local thr_rows=(
        "simple:110500:Simple rate limit (1 rule)"
        "complex:67600:Complex policy (5 rules, JWT + loop detection)"
        "llm:49400:With token estimation (tiktoken)"
    )
    for row in "${thr_rows[@]}"; do
        IFS=: read -r key tgt lbl <<< "${row}"
        local got="${THR_RES[${key}]:-N/A}"
        local col
        col=$(_col_thr "${got}" "${tgt}")
        printf "  %-48s  ${col}%-14s${RST}  %-14s\n" "${lbl}" "${got}" "${tgt}"
    done

    echo ""
    echo -e "  ${DIM}Colour: ${GRN}within 10% of target${RST}${DIM}  ${YLW}within 30% / N/A${RST}${DIM}  ${RED}>30% off${RST}"
    echo -e "${BOLD}${hr}${RST}"
    echo ""
    echo -e "  Local controller artifacts → ${BENCH_DIR}/controller-results/"
    echo -e "  Loadgen artifacts          → ${BENCH_DIR}/results/ on ${LOADGEN_REMOTE:-local}"
    echo -e "  Fairvisor logs             → ${BENCH_DIR}/run/*/logs/ on ${FAIRVISOR_REMOTE:-local}"
    echo ""
}

##############################################################################
# 11. ENTRYPOINT
##############################################################################
dispatch_helper() {
    local cmd="$1"
    shift
    case "${cmd}" in
        helper-install) helper_install "$@" ;;
        helper-start) helper_start "$@" ;;
        helper-start-fairvisor) helper_start_fairvisor "$@" ;;
        helper-stop-all) helper_stop_all ;;
        helper-run-latency) helper_run_latency "$@" ;;
        helper-run-throughput) helper_run_throughput "$@" ;;
        *)
            die "Unknown command: ${cmd}"
            ;;
    esac
}

main() {
    echo -e "${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║         FAIRVISOR BENCHMARK SUITE  v2.0                     ║"
    echo "║  Controller · Fairvisor host · Load generator host          ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${RST}"

    if [[ $# -gt 0 && "$1" == helper-* ]]; then
        dispatch_helper "$@"
        return 0
    fi

    if remote_mode_enabled; then
        controller_main
    else
        local_single_host_main
    fi
}

main "$@"
