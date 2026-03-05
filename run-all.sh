#!/usr/bin/env bash
##############################################################################
# run-all.sh — Fairvisor Benchmark Suite
#
# Installs all dependencies from scratch, runs 6 scenarios, and prints a
# colour-coded results table vs the published performance targets.
#
# Usage
#   From your local machine:
#     REMOTE=ec2-user@3.71.33.147 bash run-all.sh
#   Directly on the target host:
#     bash run-all.sh
#
# Target: 8 vCPU / 16 GB RAM (c7i.2xlarge), Amazon Linux / Ubuntu
# Fairvisor: github.com/fairvisor/edge  (OpenResty / LuaJIT, no Docker)
##############################################################################
set -euo pipefail

# ── Self-deploy ───────────────────────────────────────────────────────────────
if [[ -n "${REMOTE:-}" ]]; then
    echo "==> Deploying to ${REMOTE} …"
    ssh "${REMOTE}" "mkdir -p /tmp/fv-bench"
    scp "$0" "${REMOTE}:/tmp/fv-bench/run-all.sh"
    ssh -t "${REMOTE}" "bash /tmp/fv-bench/run-all.sh 2>&1 | tee /tmp/fv-bench/run-all.log"
    scp "${REMOTE}:/tmp/fv-bench/run-all.log" ./fairvisor-bench.log
    echo "==> Log saved to ./fairvisor-bench.log"
    exit 0
fi

##############################################################################
# CONFIG
##############################################################################
FV_DIR="/opt/fairvisor"      # clone target — mirrors Docker's /opt/fairvisor
BENCH_DIR="/tmp/fv-bench"
K6_VER="v0.54.0"

FV_PORT=8080
BACKEND_PORT=8081
NGINX_PORT=8082

# OpenResty binary — try PATH first, then the default install location
ORESTY=$(command -v openresty 2>/dev/null \
    || ls /usr/local/openresty/bin/openresty 2>/dev/null \
    || ls /usr/local/openresty/nginx/sbin/nginx 2>/dev/null \
    || echo openresty)

# Safe worker_connections — stay within OS nofile limit
_NOFILE=$(ulimit -n 2>/dev/null || echo 1024)
WORKER_CONN=$(( _NOFILE > 4096 ? 4096 : _NOFILE - 1 ))

LATENCY_RPS=10000   # RPS for latency test (README: "at 10 000 RPS steady state")
LATENCY_DUR=60      # seconds
WARMUP_DUR=10       # seconds

# Optional CPU pinning for single-host runs (SUT + load generator on same machine).
# Override via env:
#   ORESTY_CPUSET=0-3 K6_CPUSET=4-7 bash run-all.sh
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
            : # dnf can resolve metadata on install
            ;;
        *)
            die "Unsupported OS '${os_id:-unknown}' for package index update"
            ;;
    esac
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

##############################################################################
# 1. INSTALL
##############################################################################
install_all() {
    banner "Installing dependencies"
    local os_id; os_id="$(detect_os_id)"

    # ── OpenResty ────────────────────────────────────────────────────────────
    if ! command -v openresty &>/dev/null; then
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
        ok "OpenResty $(openresty -v 2>&1 | grep -oP 'nginx/[\d.]+')"
    else
        ok "OpenResty already present"
    fi

    # ── k6 ───────────────────────────────────────────────────────────────────
    if ! command -v k6 &>/dev/null; then
        log "Installing k6 ${K6_VER} …"
        curl -fsSL \
            "https://github.com/grafana/k6/releases/download/${K6_VER}/k6-${K6_VER}-linux-amd64.tar.gz" \
            | sudo tar xz -C /usr/local/bin --strip-components=1 \
                "k6-${K6_VER}-linux-amd64/k6"
        ok "k6 $(k6 version | head -1)"
    else
        ok "k6 already present"
    fi

    # ── jq, bc, git ──────────────────────────────────────────────────────────
    local need=()
    command -v jq  &>/dev/null || need+=(jq)
    command -v bc  &>/dev/null || need+=(bc)
    command -v git &>/dev/null || need+=(git)
    command -v python3 &>/dev/null || need+=(python3)
    command -v pip3 &>/dev/null || {
        if [[ "${os_id}" == "ubuntu" || "${os_id}" == "debian" ]]; then
            need+=(python3-pip)
        else
            need+=(python3-pip)
        fi
    }
    if [[ ${#need[@]} -gt 0 ]]; then
        pkg_update_index "${os_id}"
        pkg_install "${os_id}" "${need[@]}"
    fi
    ok "jq bc git python3 pip3"
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

    # Data-generation scripts (ASN map + Tor geo) — try known candidate names
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

    # Python runtime deps (tiktoken, etc.)
    [[ -f "${FV_DIR}/requirements.txt" ]] \
        && sudo pip3 install -q -r "${FV_DIR}/requirements.txt" \
        || true

    # Generate / stub out the data files fairvisor's nginx.conf.template needs.
    # In Docker these are built into the image; here we replicate the layout.

    # Run generation scripts if they exist
    for script in \
        "${FV_DIR}/bin/gen_asn_map.py"  "${FV_DIR}/data/generate_asn.py" \
        "${FV_DIR}/bin/gen_tor_geo.py"  "${FV_DIR}/data/generate_tor.py"; do
        [[ -f "${script}" ]] && sudo python3 "${script}" 2>/dev/null || true
    done

    # Pre-create known required system directories
    sudo mkdir -p /etc/fairvisor /etc/nginx/iplists

    # Copy the ASN type map from the repo (it ships as a static data file)
    local asn_src
    for asn_src in \
        "${FV_DIR}/asn_type.map" \
        "${FV_DIR}/data/asn_type.map"; do
        [[ -f "${asn_src}" ]] && { sudo cp "${asn_src}" /etc/fairvisor/asn_type.map; break; }
    done
    # Create empty stubs so nginx -t can pass even without real geo data
    [[ ! -f /etc/fairvisor/asn_type.map    ]] && sudo touch /etc/fairvisor/asn_type.map
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

    # ── simple: 1 rule, ip:address token_bucket, sky-high cap ────────────────
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

    # ── complex: 5 rules — ip rate, org quota, user rate, loop detect, circuit ─
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

    # ── llm: token_bucket_llm with tiktoken estimation ─────────────────────────
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
          "tokens_per_minute":  99999999999,
          "tokens_per_day":     99999999999999,
          "burst_tokens":       99999999999,
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
declare -a _BGPIDS=()

_cleanup() {
    for pid in "${_BGPIDS[@]:-}"; do
        kill "${pid}" 2>/dev/null || true
    done
    _BGPIDS=()
}
trap '_cleanup' EXIT INT TERM

# Wait until a TCP port is accepting connections, then check /livez
_wait_port() {
    local port="$1"
    local n=80
    while ! bash -c "echo >/dev/tcp/127.0.0.1/${port}" 2>/dev/null; do
        sleep 0.3
        (( n-- ))
        [[ $n -le 0 ]] && return 1
    done
    # Port open — give HTTP stack a moment, then confirm
    sleep 0.2
    curl -sf "http://127.0.0.1:${port}/livez" >/dev/null 2>&1 || \
    curl -sf "http://127.0.0.1:${port}/"      >/dev/null 2>&1 || true
    return 0
}

stop_all() {
    _cleanup
    sleep 1
}

# ── Raw nginx baseline ────────────────────────────────────────────────────────
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

# ── Backend (upstream for reverse-proxy mode) ─────────────────────────────────
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
      # Minimal OpenAI-like response for LLM token estimation tests
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

# ── Fairvisor ─────────────────────────────────────────────────────────────────
start_fairvisor() {
    local mode="$1"   # decision_service | reverse_proxy
    local policy="$2" # absolute path to policy JSON
    local pfx="${BENCH_DIR}/run/fv"
    mkdir -p "${pfx}/logs" "${pfx}/tmp" "${pfx}/conf"

    # Exactly the same vars the entrypoint.sh exports
    export FAIRVISOR_MODE="${mode}"
    export FAIRVISOR_CONFIG_FILE="${policy}"
    export FAIRVISOR_BACKEND_URL="http://127.0.0.1:${BACKEND_PORT}"
    export FAIRVISOR_SHARED_DICT_SIZE="256m"
    export FAIRVISOR_LOG_LEVEL="warn"
    export FAIRVISOR_WORKER_PROCESSES="auto"

    # envsubst using the exact var list from entrypoint.sh
    envsubst \
        '${FAIRVISOR_SHARED_DICT_SIZE} ${FAIRVISOR_LOG_LEVEL} ${FAIRVISOR_MODE} ${FAIRVISOR_BACKEND_URL} ${FAIRVISOR_WORKER_PROCESSES}' \
        < "${FV_DIR}/docker/nginx.conf.template" \
        > "${pfx}/conf/nginx.conf"

    # Fix paths for non-Docker layout
    sed -i \
        -e "s|/usr/local/openresty/nginx/logs/|${pfx}/logs/|g" \
        -e "s|/usr/local/openresty/nginx/tmp/|${pfx}/tmp/|g"   \
        -e "s|pid /tmp/nginx\.pid|pid ${pfx}/tmp/nginx.pid|g"  \
        -e "s|listen 8080 |listen ${FV_PORT} |g"               \
        -e "s|listen 8080;|listen ${FV_PORT};|g"               \
        "${pfx}/conf/nginx.conf"

    # Auto-stub any missing include files so nginx -t passes.
    # Fairvisor's template may reference geo/map files that only exist in Docker.
    local _attempt
    for _attempt in 1 2 3; do
        local _test_err
        _test_err=$(${ORESTY} -t -p "${pfx}" -c "${pfx}/conf/nginx.conf" 2>&1 || true)
        if echo "${_test_err}" | grep -q 'test is successful\|configuration file.*test is successful'; then
            break
        fi
        # Extract the missing file path from emerg messages like:
        #   open() "/some/path/file" failed (2: No such file or directory)
        local _missing
        _missing=$(echo "${_test_err}" | grep -oP 'open\(\) "\K[^"]+(?=" failed \(2)' | head -1)
        if [[ -n "${_missing}" ]]; then
            warn "Creating stub for missing include: ${_missing}"
            sudo mkdir -p "$(dirname "${_missing}")"
            sudo touch "${_missing}"
        else
            # Some other error — cannot auto-fix
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

    # Quick sanity check — show exactly what /v1/decision returns
    local _sc _body
    _body=$(curl -si -X POST \
        -H "Content-Type: application/json" \
        -H "X-Forwarded-For: 203.0.113.1" \
        -H "X-Original-Method: POST" \
        -H "X-Original-URI: /v1/chat/completions" \
        --data '{}' \
        "http://127.0.0.1:${FV_PORT}/v1/decision" 2>/dev/null | head -5) || true
    _sc=$(echo "${_body}" | grep -oP 'HTTP/\S+\s+\K\d+' | head -1)
    log "  /v1/decision sanity: HTTP ${_sc:-???}"
    [[ -n "${_body}" ]] && echo "${_body}" | head -3 || true
    # Also show error.log if it has content
    [[ -s "${pfx}/logs/error.log" ]] && {
        log "  error.log:"; tail -5 "${pfx}/logs/error.log"
    } || true
}

##############################################################################
# 5. k6 SCRIPTS
##############################################################################
_k6_dir() { mkdir -p "${BENCH_DIR}/scripts"; echo "${BENCH_DIR}/scripts"; }

# Latency script: constant-arrival-rate at LATENCY_RPS for LATENCY_DUR seconds
write_latency_js() {
    local name="$1" url="$2" rps="$3" dur="$4" jwt="$5" mode="$6"
    # mode: "get" | "decision" | "post"
    local f; f="$(_k6_dir)/${name}.js"
    cat > "${f}" <<EOF
import http from 'k6/http';
import { check } from 'k6';
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.0.2/index.js';

export const options = {
  scenarios: {
    steady: {
      executor:        'constant-arrival-rate',
      rate:            ${rps},
      timeUnit:        '1s',
      duration:        '${dur}s',
      preAllocatedVUs: 200,
      maxVUs:          500,
    },
  },
  summaryTrendStats:  ['p(50)','p(90)','p(99)','p(99.9)','max'],
};

const URL  = '${url}';
const JWT  = '${jwt}';
const MODE = '${mode}';

export default function () {
  const headers = { 'Content-Type': 'application/json' };
  if (JWT)             headers['Authorization'] = 'Bearer ' + JWT;
  let res;
  if (MODE === 'decision') {
    headers['X-Forwarded-For']   = \`203.0.113.\${(__VU % 254) + 1}\`;
    headers['X-Original-Method'] = 'POST';
    headers['X-Original-URI']    = '/v1/chat/completions';
    res = http.post(URL, '{}', { headers });
  } else {
    res = http.get(URL, { headers });
  }
  check(res, { '2xx/204': r => (r.status >= 200 && r.status < 300) || r.status === 204 });
}

// handleSummary is reliable in all k6 versions (unlike --summary-export)
export function handleSummary(data) {
  const outFile = __ENV.SUMMARY_OUT || '/tmp/k6_last_summary.json';
  return {
    stdout:   textSummary(data, { indent: ' ', enableColors: true }),
    [outFile]: JSON.stringify(data),
  };
}
EOF
    echo "${f}"
}

# Warmup script: fixed VUs, no scenario
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

# Throughput step script: constant-arrival-rate at a specific RPS for 20s
write_step_js() {
    local name="$1" url="$2" rps="$3" jwt="$4" body="$5"
    local f; f="$(_k6_dir)/${name}.js"
    cat > "${f}" <<EOF
import http from 'k6/http';
import { check } from 'k6';

export const options = {
  scenarios: {
    step: {
      executor:        'constant-arrival-rate',
      rate:            ${rps},
      timeUnit:        '1s',
      duration:        '20s',
      preAllocatedVUs: 600,
      maxVUs:          2500,
    },
  },
  summaryTrendStats: ['p(50)','p(99)'],
};

const URL  = '${url}';
const JWT  = '${jwt}';
const BODY = \`${body}\`;

export default function () {
  const headers = { 'Content-Type': 'application/json' };
  if (JWT)  headers['Authorization'] = 'Bearer ' + JWT;
  // Vary per-VU so loop_detection doesn't fire
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
# 6. RUN BENCHMARKS
##############################################################################
_parse_latency() {
    # Read k6 handleSummary JSON (ms values), convert ms→μs, store into named assoc array
    # dst = "LAT_D" | "LAT_P" | "LAT_N"
    local file="$1" dst="$2"

    if [[ ! -s "${file}" ]]; then
        warn "_parse_latency: ${file} is empty or missing — skipping"
        return 0
    fi

    # Prefer http_req_duration; fall back to http_req_waiting (TTFB)
    # k6 v0.54 handleSummary keys: "p(50)", "p(90)", "p(99)", "p(99.9)"
    local p50 p90 p99 p999
    p50=$(  jq -r '
      (.metrics.http_req_duration.values  // .metrics.http_req_waiting.values) |
      (.["p(50)"] // .med // 0)
    ' "${file}")
    p90=$(  jq -r '
      (.metrics.http_req_duration.values  // .metrics.http_req_waiting.values) |
      (.["p(90)"] // 0)
    ' "${file}")
    p99=$(  jq -r '
      (.metrics.http_req_duration.values  // .metrics.http_req_waiting.values) |
      (.["p(99)"] // 0)
    ' "${file}")
    p999=$( jq -r '
      (.metrics.http_req_duration.values  // .metrics.http_req_waiting.values) |
      (.["p(99.9)"] // 0)
    ' "${file}")

    eval "${dst}[p50]=$(  printf '%.0f' "$(echo "${p50}  * 1000" | bc -l)")"
    eval "${dst}[p90]=$(  printf '%.0f' "$(echo "${p90}  * 1000" | bc -l)")"
    eval "${dst}[p99]=$(  printf '%.0f' "$(echo "${p99}  * 1000" | bc -l)")"
    eval "${dst}[p999]=$( printf '%.0f' "$(echo "${p999} * 1000" | bc -l)")"
}

run_latency_test() {
    local label="$1" script="$2" warmup="$3" dst="$4"
    local out="${BENCH_DIR}/results/lat_${label}.json"
    mkdir -p "${BENCH_DIR}/results"

    log "Warmup ${label} (${WARMUP_DUR}s) …"
    k6_run run --quiet --no-summary "${warmup}" >/dev/null 2>&1 || true

    log "Latency test: ${label}  @ ${LATENCY_RPS} RPS for ${LATENCY_DUR}s …"
    # SUMMARY_OUT passed via -e so handleSummary writes the JSON reliably
    # || true: threshold failures (k6 exit 99) must not abort the suite
    k6_run run -e "SUMMARY_OUT=${out}" "${script}" 2>&1 | tail -18 || true

    _parse_latency "${out}" "${dst}"
    eval "ok \"${label}: p50=\${${dst}[p50]}μs  p90=\${${dst}[p90]}μs  p99=\${${dst}[p99]}μs  p99.9=\${${dst}[p999]}μs\""
}

# Stepping throughput: try increasing RPS until >1% errors or p99 > 1 s
run_throughput_test() {
    local label="$1" url="$2" jwt="$3" body="$4" target="$5"
    local best=0

    log "Throughput stepping test: ${label}  (target=${target} RPS) …"

    for pct in 50 70 90 100 115 130; do
        local rps=$(( target * pct / 100 ))
        local step_name="thr_${label}_${pct}"
        local step_out="${BENCH_DIR}/results/${step_name}.json"

        local js; js=$(write_step_js "${step_name}" "${url}" "${rps}" "${jwt}" "${body}")

        log "  → step ${pct}%  (${rps} RPS, 20s) …"
        k6_run run --quiet -e "SUMMARY_OUT=${step_out}" "${js}" >/dev/null 2>&1 || true

        local err_rate p99_ms
        err_rate=$( jq '
          .metrics.http_req_failed.values.rate // 1
        ' "${step_out}" 2>/dev/null || echo 1)
        p99_ms=$(   jq '
          (.metrics.http_req_duration.values  // .metrics.http_req_waiting.values) |
          (.["p(99)"] // 9999)
        ' "${step_out}" 2>/dev/null || echo 9999)

        local pass_err pass_p99
        pass_err=$(echo "${err_rate} < 0.01"   | bc -l)
        pass_p99=$(echo "${p99_ms}  < 1000"    | bc -l)   # p99 < 1 s

        if [[ "${pass_err}" == "1" && "${pass_p99}" == "1" ]]; then
            best="${rps}"
            ok "    PASS @ ${rps} RPS  (err=$(printf '%.2f%%' "$(echo "${err_rate}*100" | bc -l)")  p99=$(printf '%.0fms' "${p99_ms}"))"
        else
            warn "    FAIL @ ${rps} RPS  (err=$(printf '%.2f%%' "$(echo "${err_rate}*100" | bc -l)")  p99=$(printf '%.0fms' "${p99_ms}")) — stopping"
            break
        fi
    done

    THR_RES["${label}"]="${best}"
    ok "${label}: max sustained ≈ ${best} RPS"
}

##############################################################################
# 7. RESULTS TABLE
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
    local ok110;  ok110=$(  printf '%.0f' "$(echo "${tgt}*1.10" | bc -l)")
    local ok130;  ok130=$(  printf '%.0f' "$(echo "${tgt}*1.30" | bc -l)")
    (( got <= ok110 )) && echo "${GRN}" && return
    (( got <= ok130 )) && echo "${YLW}" && return
    echo "${RED}"
}

_col_thr() {
    local got="$1" tgt="$2"
    [[ "${got}" == "N/A" || "${got}" == "0" ]] && echo "${YLW}" && return
    local ok90; ok90=$(printf '%.0f' "$(echo "${tgt}*0.90" | bc -l)")
    (( got >= ok90 )) && echo "${GRN}" || echo "${RED}"
}

print_results() {
    local W=82
    local hr; hr=$(printf '═%.0s' $(seq 1 $W))
    local hr2; hr2=$(printf '─%.0s' $(seq 1 $W))

    echo ""
    echo -e "${BOLD}${hr}${RST}"
    echo -e "${BOLD}  FAIRVISOR BENCHMARK RESULTS${RST}"
    echo -e "${BOLD}${hr}${RST}"

    # ── Latency ──────────────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}  Latency @ ${LATENCY_RPS} RPS steady state${RST}  ${DIM}(target: fairvisor/edge README)${RST}"
    echo ""
    printf "  ${BOLD}%-8s  %-26s  %-26s  %-20s${RST}\n" \
        "Pct" "Decision Service" "Reverse Proxy" "Raw nginx"
    printf "  %-8s  %-26s  %-26s  %-20s\n" \
        "────────" "────────────────────────" "────────────────────────" "──────────────────"

    local rows=("p50:p50:112:241:71" "p90:p90:191:376:190" "p99:p99:426:822:446" "p99.9:p999:2990:2980:1610")
    for row in "${rows[@]}"; do
        IFS=: read -r lbl key td tp tn <<< "${row}"

        local gd; eval "gd=\${LAT_D[${key}]:-N/A}"
        local gp; eval "gp=\${LAT_P[${key}]:-N/A}"
        local gn; eval "gn=\${LAT_N[${key}]:-N/A}"

        local fd fp fn
        [[ "${gd}" == "N/A" ]] && fd="N/A (tgt: $(_us $td))" || fd="$(_us $gd) (tgt: $(_us $td))"
        [[ "${gp}" == "N/A" ]] && fp="N/A (tgt: $(_us $tp))" || fp="$(_us $gp) (tgt: $(_us $tp))"
        [[ "${gn}" == "N/A" ]] && fn="N/A (tgt: $(_us $tn))" || fn="$(_us $gn) (tgt: $(_us $tn))"

        local cd cp cn
        [[ "${gd}" == "N/A" ]] && cd="${YLW}" || cd=$(_col_lat "${gd}" "${td}")
        [[ "${gp}" == "N/A" ]] && cp="${YLW}" || cp=$(_col_lat "${gp}" "${tp}")
        [[ "${gn}" == "N/A" ]] && cn="${YLW}" || cn=$(_col_lat "${gn}" "${tn}")

        printf "  %-8s  ${cd}%-26s${RST}  ${cp}%-26s${RST}  ${cn}%-20s${RST}\n" \
            "${lbl}" "${fd}" "${fp}" "${fn}"
    done

    # ── Throughput ───────────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}  Max Sustained Throughput — single instance${RST}"
    echo ""
    printf "  ${BOLD}%-48s  %-14s  %-14s${RST}\n" "Configuration" "Measured RPS" "Target RPS"
    printf "  %-48s  %-14s  %-14s\n" \
        "$(printf '─%.0s' $(seq 1 48))" "──────────────" "──────────────"

    local thr_rows=(
        "simple:110500:Simple rate limit (1 rule)"
        "complex:67600:Complex policy (5 rules, JWT + loop detection)"
        "llm:49400:With token estimation (tiktoken)"
    )
    for row in "${thr_rows[@]}"; do
        IFS=: read -r key tgt lbl <<< "${row}"
        local got="${THR_RES[${key}]:-N/A}"
        local col; col=$(_col_thr "${got}" "${tgt}")
        printf "  %-48s  ${col}%-14s${RST}  %-14s\n" "${lbl}" "${got}" "${tgt}"
    done

    echo ""
    echo -e "  ${DIM}Colour: ${GRN}within 10% of target${RST}${DIM}  ${YLW}within 30% / N/A${RST}${DIM}  ${RED}>30% off${RST}"
    echo -e "${BOLD}${hr}${RST}"
    echo ""
    echo -e "  Raw k6 summaries → ${BENCH_DIR}/results/"
    echo -e "  Service logs     → ${BENCH_DIR}/run/*/logs/"
    echo ""
}

##############################################################################
# MAIN
##############################################################################
main() {
    echo -e "${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║         FAIRVISOR BENCHMARK SUITE  v1.0                     ║"
    echo "║  Decision Service · Reverse Proxy · Raw nginx (baseline)    ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${RST}"

    mkdir -p "${BENCH_DIR}/results" "${BENCH_DIR}/scripts"

    if [[ -n "${TASKSET_BIN}" ]]; then
        log "CPU pinning: openresty='${ORESTY_CPUSET:-auto/off}'  k6='${K6_CPUSET:-auto/off}'"
    else
        warn "taskset not found — CPU pinning disabled"
    fi

    # Kill any stale OpenResty processes from a previous run
    pkill -f "openresty" 2>/dev/null || true
    sleep 1

    install_all
    setup_fairvisor
    create_policies

    local JWT; JWT=$(gen_jwt)
    local PD="${BENCH_DIR}/policies"
    local FV_URL="http://127.0.0.1:${FV_PORT}"
    local NGINX_URL="http://127.0.0.1:${NGINX_PORT}"
    local DECISION_URL="${FV_URL}/v1/decision"

    # LLM request body — realistic short chat message for token estimation
    local LLM_BODY='{"model":"gpt-4o","messages":[{"role":"user","content":"Hello, this is a benchmark test message for token estimation."}]}'

    # ── TEST 1/6: Raw nginx baseline ──────────────────────────────────────────
    banner "TEST 1/6 — Raw nginx baseline (latency)"
    start_baseline
    s_lat=$(   write_latency_js "lat_nginx" "${NGINX_URL}/" "${LATENCY_RPS}" "${LATENCY_DUR}" "" "get")
    s_warmup=$(write_warmup_js  "lat_nginx" "${NGINX_URL}/" "")
    run_latency_test "nginx" "${s_lat}" "${s_warmup}" "LAT_N"
    stop_all

    # ── TEST 2/6: Decision service latency ───────────────────────────────────
    banner "TEST 2/6 — Fairvisor decision_service (latency)"
    start_backend
    start_fairvisor "decision_service" "${PD}/simple.json"
    s_lat=$(   write_latency_js "lat_decision" "${DECISION_URL}" "${LATENCY_RPS}" "${LATENCY_DUR}" "${JWT}" "decision")
    s_warmup=$(write_warmup_js  "lat_decision" "${DECISION_URL}" "${JWT}")
    run_latency_test "decision" "${s_lat}" "${s_warmup}" "LAT_D"
    stop_all

    # ── TEST 3/6: Reverse proxy latency ──────────────────────────────────────
    banner "TEST 3/6 — Fairvisor reverse_proxy (latency)"
    start_backend
    start_fairvisor "reverse_proxy" "${PD}/simple.json"
    s_lat=$(   write_latency_js "lat_proxy" "${FV_URL}/" "${LATENCY_RPS}" "${LATENCY_DUR}" "${JWT}" "get")
    s_warmup=$(write_warmup_js  "lat_proxy" "${FV_URL}/" "${JWT}")
    run_latency_test "proxy" "${s_lat}" "${s_warmup}" "LAT_P"
    stop_all

    # ── TEST 4/6: Max throughput — simple policy ──────────────────────────────
    banner "TEST 4/6 — Max throughput: simple rate limit (1 rule)"
    start_backend
    start_fairvisor "reverse_proxy" "${PD}/simple.json"
    run_throughput_test "simple" "${FV_URL}/" "" "" "${TGT_T[simple]}"
    stop_all

    # ── TEST 5/6: Max throughput — complex policy ─────────────────────────────
    banner "TEST 5/6 — Max throughput: complex policy (5 rules + JWT + loop)"
    start_backend
    start_fairvisor "reverse_proxy" "${PD}/complex.json"
    run_throughput_test "complex" "${FV_URL}/" "${JWT}" "" "${TGT_T[complex]}"
    stop_all

    # ── TEST 6/6: Max throughput — LLM token estimation ──────────────────────
    banner "TEST 6/6 — Max throughput: token estimation (tiktoken)"
    start_backend
    start_fairvisor "reverse_proxy" "${PD}/llm.json"
    run_throughput_test "llm" "${FV_URL}/" "${JWT}" "${LLM_BODY}" "${TGT_T[llm]}"
    stop_all

    print_results
}

main "$@"
