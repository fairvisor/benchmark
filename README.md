# Fairvisor Benchmark Suite

Single-script benchmark suite for `fairvisor/edge` with reproducible latency and throughput tests.

Script: `run-all.sh`

## What It Tests

`run-all.sh` runs 6 scenarios:

1. Raw nginx baseline latency (`:8082`)
2. Fairvisor `decision_service` latency (`POST /v1/decision`)
3. Fairvisor `reverse_proxy` latency
4. Max throughput: simple policy (1 rule)
5. Max throughput: complex policy (5 rules + JWT + loop detection)
6. Max throughput: LLM token estimation policy (`token_bucket_llm`)

Each run prints a summary table and stores raw artifacts.

## Environment

- Designed for Linux hosts (Amazon Linux / Ubuntu)
- Installs dependencies automatically:
  - OpenResty
  - k6
  - jq, bc, git, python3, pip3
- Clones `https://github.com/fairvisor/edge` into `/opt/fairvisor`

## Quick Start

Run directly on target host:

```bash
bash run-all.sh
```

Run from local machine and execute remotely:

```bash
REMOTE=ubuntu@<host> bash run-all.sh
```

When `REMOTE` is set, the script copies itself to `/tmp/fv-bench/run-all.sh`, executes there, and downloads log to `./fairvisor-bench.log`.

## CPU Pinning (Single-Host Mode)

For setups where SUT and k6 share one host, optional `taskset` pinning is supported.

- `ORESTY_CPUSET` for OpenResty/backend processes
- `K6_CPUSET` for k6

Example:

```bash
ORESTY_CPUSET=0-3 K6_CPUSET=4-7 bash run-all.sh
```

If `taskset` exists and host has `>=8` cores, defaults are auto-split 50/50.

## Outputs

On target host:

- Raw k6 summaries: `/tmp/fv-bench/results/`
- Generated k6 scripts: `/tmp/fv-bench/scripts/`
- Service logs: `/tmp/fv-bench/run/*/logs/`
- Full run log: `/tmp/fv-bench/run-all.log`

Local (when `REMOTE` is used):

- Downloaded run log: `./fairvisor-bench.log`

## Reference Results

Measured on **AWS c7i.2xlarge** (8 vCPU, 16 GB RAM), **Ubuntu 24.04.3 LTS**.
k6 v0.54.0, constant-arrival-rate, 10 000 RPS / 60 s / 10 s warmup.
CPU pinning: OpenResty on cores 0–3, k6 on cores 4–7.

### Latency @ 10 000 RPS

| Percentile | Decision Service | Reverse Proxy | Raw nginx |
|------------|-----------------|---------------|-----------|
| p50        | 112 μs          | 241 μs        | 71 μs     |
| p90        | 191 μs          | 376 μs        | 190 μs    |
| p99        | 426 μs          | 822 μs        | 446 μs    |
| p99.9      | 2 990 μs        | 2 980 μs      | 1 610 μs  |

### Max Sustained Throughput — single instance

| Configuration                              | RPS     |
|--------------------------------------------|---------|
| Simple rate limit (1 rule)                 | 110 500 |
| Complex policy (5 rules, JWT + loop detect)| 67 600  |
| Token estimation (token_bucket_llm)        | 49 400  |

> Your numbers will vary by instance type and OS.
> Use `results/reference.json` to compare programmatically.

## Notes on Interpretation

- `decision_service` and `reverse_proxy` are different paths:
  - `decision_service`: decision API only
  - `reverse_proxy`: decision + upstream proxy round-trip
- In single-host runs, k6 and SUT can contend for CPU unless pinned/separated.
- For production-like proxy latency, prefer separate load-generator host.

## Repository

This benchmark suite is intended to be published in:

- `https://github.com/fairvisor/benchmark`

