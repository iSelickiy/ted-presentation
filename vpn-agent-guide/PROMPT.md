# MyOwnVPN — Промпт для AI-агента

## Твоя задача

Разверни проект `myownvpn` — персональный dual-egress VPN с нуля.

Ты должен создать ВСЕ файлы проекта, запросить у пользователя данные о серверах,
заполнить конфиги, сгенерировать ключи, развернуть всё на двух VPS серверах,
проверить работоспособность и выдать готовые клиентские конфиги.

**Важно:** следуй инструкциям строго по порядку. Не пропускай шаги. Если на
каком-то шаге возникает ошибка — остановись и сообщи пользователю что именно
пошло не так, не продолжай дальше.

---

## Порядок выполнения

### Фаза 0: Создай AGENTS.md — главный файл инструкций для агента

Первым делом создай файл `AGENTS.md` в корне проекта со следующим содержимым:

```markdown
# Agent Guide for `myownvpn`

This repository manages a personal dual-egress VPN. Treat it as infrastructure,
not as a normal application repo.

## First Read

Start with these files, in order:
1. `AGENTS.md` — operational rules for coding assistants.
2. `README.md` — human-facing navigation hub, quick start, recovery checklist.
3. `docs/architecture.md` — system architecture, tech stack, data flow, rule format.

## What This Project Does

- Clients use `AmneziaVPN`.
- Clients connect to the RU node through `VLESS + Reality` served by `sing-box`.
- The RU node routes traffic by rule sets.
- Traffic that should use foreign egress goes from RU to the foreign node over `WireGuard`.
- The foreign node does NAT and exits to the internet through its public IP.
- Current routing mode is `foreign-by-default`.

## Source of Truth

Edit these files when changing behavior:
- `config/users.yaml` — client profiles.
- `rules/ru-direct.seed.txt` — domains/IPs that should exit through RU.
- `rules/foreign.seed.txt` — domains/IPs that should exit through foreign.
- `rules/local-bypass.seed.txt` — local/reserved routes and overrides.
- `inventory/servers.env` — server addresses, SSH auth, static network settings.
- `inventory/runtime-secrets.env` — existing runtime keys used by deployed servers.

Generated files live under `build/`. Do not hand-edit `build/` as the source of
truth. Regenerate it with:

```bash
python3 scripts/render_artifacts.py --strict
```

## Normal Deploy Flow

For routine user or routing-rule changes:

```bash
python3 scripts/render_artifacts.py --strict
bash scripts/bootstrap_cluster.sh --apply-only
```

`--apply-only` reuses `inventory/runtime-secrets.env`, renders `build/`, backs up
remote configs, uploads generated artifacts, restarts services, then runs
`health_check.sh` and `smoke_check.sh`.

Use this for:
- adding a user in `config/users.yaml`;
- disabling a user with `enabled: false`;
- changing routing rules in `rules/*.seed.txt` or adding `rules/overrides/*.txt`.

## Fresh Server Bootstrap

Only use a full bootstrap for fresh VPS instances or an intentional rebuild:

```bash
bash scripts/bootstrap_cluster.sh
```

Never run this casually on an already working deployment.

## Forbidden Without Explicit User Approval

- Do not run `bash scripts/bootstrap_cluster.sh --refresh-secrets`.
- Do not delete or recreate `inventory/runtime-secrets.env`.
- Do not change `PROJECT_SLUG` if existing clients must keep working.
- Do not publish or paste `inventory/*.env`, `build/clients/*`, VLESS URIs, or private keys.
- Do not manually edit remote `/etc/sing-box`, `/etc/wireguard`, or nftables config as the primary path; use the render/apply pipeline.

## User Management

To issue a new client profile:
1. Add a user to `config/users.yaml`.
2. Leave `uuid` and `short_id` empty unless preserving an existing identity.
3. Run: `python3 scripts/render_artifacts.py --strict && bash scripts/bootstrap_cluster.sh --apply-only`
4. Give the user their generated `build/clients/<name>.xray.json`.

To revoke access:
1. Set `enabled: false` for that user in `config/users.yaml`.
2. Run: `bash scripts/bootstrap_cluster.sh --apply-only`

The old client file may remain archived locally, but the server should no longer
accept that UUID after apply.

Client configs appear in `build/clients/<name>.xray.json` — import into AmneziaVPN.
The server uses one global Reality keypair; each enabled client gets its own
UUID and Reality short ID.

## Routing Rules

Edit seed files in `rules/`:
- `local-bypass.seed.txt` — addresses never routed through foreign
- `ru-direct.seed.txt` — services that should exit via RU IP
- `foreign.seed.txt` — services explicitly routed through foreign
- `overrides/*.txt` — per-service overrides

Supported formats: `example.com`, `.example.com`, `*.example.com`, `keyword:xxx`,
`regex:...`, `1.2.3.0/24`.
The renderer rejects identical normalized rules that appear in both
`ru-direct` and `foreign`.

## Rollback

If an apply breaks the deployment, `bootstrap_cluster.sh --apply-only` prints backup
archive paths. Restore with:

```bash
bash scripts/rollback_remote.sh --node ru --archive /var/backups/myownvpn/<archive>.tar.gz
bash scripts/rollback_remote.sh --node foreign --archive /var/backups/myownvpn/<archive>.tar.gz
```

Then re-run health and smoke checks.

## Safe Local Checks

Run these after opening the repo on a new machine:

```bash
ssh -V
scp -V
python3 --version
sshpass -V
test -f inventory/servers.env
test -f inventory/runtime-secrets.env
test -f config/users.yaml
chmod 600 inventory/servers.env inventory/runtime-secrets.env
bash -n scripts/bootstrap_cluster.sh scripts/health_check.sh scripts/smoke_check.sh scripts/backup_remote.sh scripts/rollback_remote.sh scripts/lib/common.sh
python3 scripts/render_artifacts.py --strict
```

If `sshpass` is missing on macOS:

```bash
brew install hudochenkov/sshpass/sshpass
```

## Security Rules for Agents

- NEVER expose passwords, private keys, preshared keys, Reality keys, UUIDs, VLESS links, or full generated client configs in chat or logs.
- When reporting status, mention only public IPs and non-secret service names.
- If a command fails because of sandbox or network restrictions, say that explicitly and request permission to retry.
```

Запиши этот файл как `AGENTS.md` в текущей директории.

---

### Фаза 1: Создай структуру директорий

Создай следующие директории (если ещё не существуют):

```bash
mkdir -p config
mkdir -p inventory
mkdir -p rules/overrides
mkdir -p scripts/lib
mkdir -p build
mkdir -p docs
mkdir -p .github/workflows
```

---

### Фаза 2: Напиши все скрипты

Создай каждый файл с ТОЧНО таким содержимым, как указано ниже. Не меняй ни одной строки.

#### 2.1 `scripts/lib/common.sh`

```bash
#!/usr/bin/env bash

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
  printf '[%s] WARN: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

die() {
  printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
  exit 1
}

repo_root() {
  local source_dir
  source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  printf '%s\n' "$source_dir"
}

ensure_bin() {
  local bin
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || die "Required binary not found: $bin"
  done
}

ensure_file() {
  local path="$1"
  [[ -f "$path" ]] || die "Required file not found: $path"
}

load_env_file() {
  local env_file="$1"
  [[ -f "$env_file" ]] || die "Missing env file: $env_file"
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
}

require_vars() {
  local name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || die "Required variable is empty: $name"
  done
}

node_ssh_host() {
  case "$1" in
    ru) printf '%s\n' "$RU_SSH_HOST" ;;
    foreign) printf '%s\n' "$FOREIGN_SSH_HOST" ;;
    *) die "Unknown node: $1" ;;
  esac
}

node_ssh_port() {
  case "$1" in
    ru) printf '%s\n' "$RU_SSH_PORT" ;;
    foreign) printf '%s\n' "$FOREIGN_SSH_PORT" ;;
    *) die "Unknown node: $1" ;;
  esac
}

node_ssh_user() {
  case "$1" in
    ru) printf '%s\n' "$RU_SSH_USER" ;;
    foreign) printf '%s\n' "$FOREIGN_SSH_USER" ;;
    *) die "Unknown node: $1" ;;
  esac
}

node_ssh_password() {
  case "$1" in
    ru) printf '%s\n' "${RU_SSH_PASSWORD:-}" ;;
    foreign) printf '%s\n' "${FOREIGN_SSH_PASSWORD:-}" ;;
    *) die "Unknown node: $1" ;;
  esac
}

node_ssh_identity_file() {
  case "$1" in
    ru) printf '%s\n' "${RU_SSH_IDENTITY_FILE:-}" ;;
    foreign) printf '%s\n' "${FOREIGN_SSH_IDENTITY_FILE:-}" ;;
    *) die "Unknown node: $1" ;;
  esac
}

node_target() {
  local node="$1"
  printf '%s@%s\n' "$(node_ssh_user "$node")" "$(node_ssh_host "$node")"
}

ensure_node_auth_ready() {
  local node="$1"
  local password identity
  password="$(node_ssh_password "$node")"
  identity="$(node_ssh_identity_file "$node")"

  if [[ -n "$password" ]]; then
    ensure_bin sshpass
    return
  fi

  if [[ -n "$identity" ]]; then
    ensure_file "$identity"
  fi
}

run_ssh() {
  local node="$1"
  shift
  local password identity
  local -a cmd

  ensure_node_auth_ready "$node"
  password="$(node_ssh_password "$node")"
  identity="$(node_ssh_identity_file "$node")"

  if [[ -n "$password" ]]; then
    cmd=(
      env "SSHPASS=$password"
      sshpass -e
      ssh
    )
  else
    cmd=(
      ssh
      -o BatchMode=yes
    )
    if [[ -n "$identity" ]]; then
      cmd+=(-i "$identity")
    fi
  fi

  cmd+=(
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=10
    -p "$(node_ssh_port "$node")"
    "$(node_target "$node")"
    "$@"
  )

  "${cmd[@]}"
}

copy_to_node() {
  local node="$1"
  local src="$2"
  local dst="$3"
  local password identity
  local -a cmd

  ensure_node_auth_ready "$node"
  password="$(node_ssh_password "$node")"
  identity="$(node_ssh_identity_file "$node")"

  if [[ -n "$password" ]]; then
    cmd=(
      env "SSHPASS=$password"
      sshpass -e
      scp
    )
  else
    cmd=(
      scp
      -o BatchMode=yes
    )
    if [[ -n "$identity" ]]; then
      cmd+=(-i "$identity")
    fi
  fi

  cmd+=(
    -P "$(node_ssh_port "$node")"
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=10
    "$src"
    "$(node_target "$node"):$dst"
  )

  "${cmd[@]}"
}

copy_from_node() {
  local node="$1"
  local src="$2"
  local dst="$3"
  local password identity
  local -a cmd

  ensure_node_auth_ready "$node"
  password="$(node_ssh_password "$node")"
  identity="$(node_ssh_identity_file "$node")"

  if [[ -n "$password" ]]; then
    cmd=(
      env "SSHPASS=$password"
      sshpass -e
      scp
    )
  else
    cmd=(
      scp
      -o BatchMode=yes
    )
    if [[ -n "$identity" ]]; then
      cmd+=(-i "$identity")
    fi
  fi

  cmd+=(
    -P "$(node_ssh_port "$node")"
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=10
    "$(node_target "$node"):$src"
    "$dst"
  )

  "${cmd[@]}"
}
```

Запиши и сделай исполняемым: `chmod +x scripts/lib/common.sh`

#### 2.2 `scripts/render_artifacts.py`

Создай файл `scripts/render_artifacts.py` со следующим содержимым:

```python
#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import pathlib
import sys
import urllib.parse
import uuid
from typing import Any

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[1]

STATIC_REQUIRED_KEYS = [
    "PROJECT_SLUG",
    "RU_PUBLIC_IP",
    "RU_PRIMARY_NIC",
    "FOREIGN_PUBLIC_IP",
    "FOREIGN_PRIMARY_NIC",
    "WG_INTERFACE",
    "WG_PORT",
    "WG_TUNNEL_CIDR",
    "WG_RU_ADDRESS",
    "WG_FOREIGN_ADDRESS",
    "WG_MTU",
    "WG_PERSISTENT_KEEPALIVE",
    "WG_ROUTE_TABLE",
    "WG_ROUTE_MARK",
    "REALITY_LISTEN_PORT",
    "REALITY_HANDSHAKE_SERVER",
    "REALITY_HANDSHAKE_PORT",
    "REALITY_SERVER_NAME",
    "REALITY_FLOW",
    "REALITY_CLIENT_FINGERPRINT",
    "RU_DNS_SERVER",
    "RU_DNS_PORT",
    "FOREIGN_DNS_SERVER",
    "FOREIGN_DNS_PORT",
    "DEBUG_MIXED_LISTEN",
    "DEBUG_MIXED_PORT",
]

SECRET_KEYS = [
    "WG_PRESHARED_KEY",
    "WG_RU_PRIVATE_KEY",
    "WG_RU_PUBLIC_KEY",
    "WG_FOREIGN_PRIVATE_KEY",
    "WG_FOREIGN_PUBLIC_KEY",
    "REALITY_PRIVATE_KEY",
    "REALITY_PUBLIC_KEY",
]

PORT_FIELDS = [
    "WG_PORT",
    "REALITY_LISTEN_PORT",
    "REALITY_HANDSHAKE_PORT",
    "RU_DNS_PORT",
    "FOREIGN_DNS_PORT",
    "DEBUG_MIXED_PORT",
]

POSITIVE_INTEGER_FIELDS = [
    "WG_ROUTE_MARK",
    "WG_ROUTE_TABLE",
]

WG_NETWORK_FIELDS = [
    "WG_TUNNEL_CIDR",
]

WG_INTERFACE_FIELDS = [
    "WG_RU_ADDRESS",
    "WG_FOREIGN_ADDRESS",
]

LOOPBACK_LISTEN_VALUES = {"127.0.0.1", "::1", "localhost"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Render v1 dual-egress VPN artifacts.")
    parser.add_argument(
        "--env",
        default=str(ROOT / "inventory" / "servers.env"),
        help="Path to the filled servers env file.",
    )
    parser.add_argument(
        "--runtime-secrets",
        default=str(ROOT / "inventory" / "runtime-secrets.env"),
        help="Path to runtime secrets collected during bootstrap.",
    )
    parser.add_argument(
        "--users",
        default=str(ROOT / "config" / "users.yaml"),
        help="Path to the filled users yaml file.",
    )
    parser.add_argument(
        "--build-dir",
        default=str(ROOT / "build"),
        help="Output directory for generated artifacts.",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Fail if any runtime secret is missing instead of inserting placeholders.",
    )
    return parser.parse_args()


def parse_env_file(path: pathlib.Path) -> dict[str, str]:
    data: dict[str, str] = {}
    if not path.exists():
        raise FileNotFoundError(path)
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in raw_line:
            raise ValueError(f"Invalid env line in {path}: {raw_line}")
        key, value = raw_line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        data[key] = value
    return data


def parse_users_yaml(path: pathlib.Path) -> list[dict[str, Any]]:
    if not path.exists():
        raise FileNotFoundError(path)
    with path.open("r", encoding="utf-8") as f:
        data = yaml.safe_load(f)
    if not data or "users" not in data:
        raise ValueError(f"No 'users' key found in {path}")
    users = data["users"]
    if not isinstance(users, list) or not users:
        raise ValueError(f"No users found in {path}")
    return users


def slugify(value: str) -> str:
    lowered = value.strip().lower().replace(" ", "-").replace("_", "-")
    chars = []
    for ch in lowered:
        if ch.isalnum() or ch == "-":
            chars.append(ch)
    cleaned = "".join(chars).strip("-")
    if not cleaned:
        raise ValueError(f"Cannot slugify empty value: {value!r}")
    return cleaned


def derive_uuid(project_slug: str, user_name: str) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_DNS, f"{project_slug}:{user_name}"))


def derive_short_id(project_slug: str, user_name: str) -> str:
    digest = hashlib.sha256(f"{project_slug}:{user_name}".encode("utf-8")).hexdigest()
    return digest[:8]


def normalize_user(project_slug: str, raw_user: dict[str, Any]) -> dict[str, Any]:
    name = slugify(str(raw_user.get("name", "")))
    enabled = bool(raw_user.get("enabled", True))
    display_name = str(raw_user.get("display_name", name))
    flow = str(raw_user.get("flow", "")) or ""
    uuid_value = str(raw_user.get("uuid", "")).strip() or derive_uuid(project_slug, name)
    short_id = str(raw_user.get("short_id", "")).strip() or derive_short_id(project_slug, name)
    short_id = short_id.lower()
    if len(short_id) > 8 or any(ch not in "0123456789abcdef" for ch in short_id):
        raise ValueError(f"Invalid short_id for user {name}: {short_id}")

    return {
        "name": name,
        "display_name": display_name,
        "enabled": enabled,
        "platform": str(raw_user.get("platform", "")).strip(),
        "notes": str(raw_user.get("notes", "")).strip(),
        "uuid": uuid_value,
        "short_id": short_id,
        "flow": flow,
    }


def classify_rule_line(line: str) -> tuple[str, str]:
    if ":" in line:
        prefix, payload = line.split(":", 1)
        prefix = prefix.strip().lower()
        payload = payload.strip()
        if prefix in {"full", "suffix", "keyword", "regex"}:
            return prefix, payload
    try:
        ipaddress.ip_network(line, strict=False)
        return "ip_cidr", line
    except ValueError:
        pass
    if line.startswith("*."):
        return "suffix", line[1:]
    if line.startswith("."):
        return "suffix", line
    if line.count(".") >= 1:
        return "domain_or_suffix", line
    return "domain", line


def read_rule_files(base_file: pathlib.Path, override_glob: str) -> list[str]:
    lines: list[str] = []
    for path in [base_file, *sorted((base_file.parent / "overrides").glob(override_glob))]:
        if not path.exists():
            continue
        for raw_line in path.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            lines.append(line)
    return lines


def rule_conflict_keys(line: str) -> set[tuple[str, str]]:
    """Return normalized keys used to detect direct conflicts between route lists."""
    kind, value = classify_rule_line(line)
    if kind in {"full", "domain"}:
        return {("domain", value)}
    if kind == "suffix":
        suffix = value if value.startswith(".") else f".{value}"
        return {("domain_suffix", suffix)}
    if kind == "domain_or_suffix":
        suffix = value if value.startswith(".") else f".{value}"
        return {("domain", value), ("domain_suffix", suffix)}
    if kind == "ip_cidr":
        return {("ip_cidr", str(ipaddress.ip_network(value, strict=False)))}
    if kind == "keyword":
        return {("domain_keyword", value)}
    if kind == "regex":
        return {("domain_regex", value)}
    raise ValueError(f"Unsupported rule line: {line}")


def validate_no_rule_conflicts(ru_lines: list[str], foreign_lines: list[str]) -> None:
    """Fail when the same normalized rule is present in both route destinations."""
    ru_keys: dict[tuple[str, str], str] = {}
    for line in ru_lines:
        for key in rule_conflict_keys(line):
            ru_keys.setdefault(key, line)

    for line in foreign_lines:
        for key in rule_conflict_keys(line):
            if key in ru_keys:
                kind, value = key
                raise ValueError(
                    "conflicting routing rule in ru-direct and foreign: "
                    f"{kind}:{value} ({ru_keys[key]!r} vs {line!r})"
                )


def build_rule_set(lines: list[str], extra_ip_cidrs: list[str]) -> dict[str, Any]:
    domains: set[str] = set()
    suffixes: set[str] = set()
    keywords: set[str] = set()
    regexes: set[str] = set()
    cidrs: set[str] = set(extra_ip_cidrs)

    for line in lines:
        kind, value = classify_rule_line(line)
        if kind == "full" or kind == "domain":
            domains.add(value)
            continue
        if kind == "suffix":
            suffixes.add(value if value.startswith(".") else f".{value}")
            continue
        if kind == "keyword":
            keywords.add(value)
            continue
        if kind == "regex":
            regexes.add(value)
            continue
        if kind == "ip_cidr":
            cidrs.add(value)
            continue
        if kind == "domain_or_suffix":
            normalized = value if value.startswith(".") else f".{value}"
            if value in domains or normalized in suffixes:
                print(
                    f"WARN: duplicate rule '{value}' in domain_or_suffix",
                    file=sys.stderr,
                )
            domains.add(value)
            suffixes.add(normalized)
            continue
        raise ValueError(f"Unsupported rule line: {line}")

    rules: list[dict[str, Any]] = []
    if domains:
        rules.append({"domain": sorted(domains)})
    if suffixes:
        rules.append({"domain_suffix": sorted(suffixes)})
    if keywords:
        rules.append({"domain_keyword": sorted(keywords)})
    if regexes:
        rules.append({"domain_regex": sorted(regexes)})
    if cidrs:
        rules.append({"ip_cidr": sorted(cidrs)})
    return {"version": 4, "rules": rules}


def ensure_keys_present(data: dict[str, str], strict: bool) -> list[str]:
    missing = []
    for key in STATIC_REQUIRED_KEYS:
        if not data.get(key):
            missing.append(key)
    if strict and missing:
        raise ValueError(f"Missing required static keys: {', '.join(missing)}")
    return missing


def _validate_port(env: dict[str, str], key: str) -> None:
    value = env.get(key, "").strip()
    if not value:
        return
    try:
        port = int(value)
    except ValueError as exc:
        raise ValueError(f"{key} must be an integer port from 1 to 65535") from exc
    if not 1 <= port <= 65535:
        raise ValueError(f"{key} must be an integer port from 1 to 65535")


def _validate_positive_integer(env: dict[str, str], key: str) -> None:
    value = env.get(key, "").strip()
    if not value:
        return
    try:
        number = int(value)
    except ValueError as exc:
        raise ValueError(f"{key} must be a positive integer") from exc
    if number <= 0:
        raise ValueError(f"{key} must be a positive integer")


def _validate_ip_network(env: dict[str, str], key: str) -> None:
    value = env.get(key, "").strip()
    if not value:
        return
    try:
        ipaddress.ip_network(value, strict=True)
    except ValueError as exc:
        raise ValueError(f"{key} must be a valid IP network CIDR") from exc


def _validate_ip_interface(env: dict[str, str], key: str) -> None:
    value = env.get(key, "").strip()
    if not value:
        return
    try:
        ipaddress.ip_interface(value)
    except ValueError as exc:
        raise ValueError(f"{key} must be a valid IP interface CIDR") from exc


def validate_env(env: dict[str, str]) -> None:
    debug_listen = env.get("DEBUG_MIXED_LISTEN", "").strip().lower()
    if debug_listen and debug_listen not in LOOPBACK_LISTEN_VALUES:
        raise ValueError(
            "DEBUG_MIXED_LISTEN must be loopback-only: 127.0.0.1, ::1, or localhost"
        )

    for key in PORT_FIELDS:
        _validate_port(env, key)
    for key in POSITIVE_INTEGER_FIELDS:
        _validate_positive_integer(env, key)
    for key in WG_NETWORK_FIELDS:
        _validate_ip_network(env, key)
    for key in WG_INTERFACE_FIELDS:
        _validate_ip_interface(env, key)


def get_secret(
    combined: dict[str, str],
    key: str,
    placeholders: list[str],
    strict: bool,
) -> str:
    value = combined.get(key, "").strip()
    if value:
        return value
    placeholder = f"__MISSING_{key}__"
    placeholders.append(key)
    if strict:
        raise ValueError(f"Missing runtime secret: {key}")
    return placeholder


def write_text(path: pathlib.Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def write_json(path: pathlib.Path, payload: Any) -> None:
    write_text(path, json.dumps(payload, indent=2, ensure_ascii=True) + "\n")


def host_ip(cidr: str) -> str:
    return str(ipaddress.ip_interface(cidr).ip)


def int_or_string(value: str) -> int | str:
    stripped = value.strip()
    return int(stripped) if stripped.isdigit() else stripped


def render_vless_uri(env: dict[str, str], user: dict[str, Any], global_reality_public_key: str) -> str:
    params = {
        "encryption": "none",
        "flow": user["flow"] or env["REALITY_FLOW"],
        "security": "reality",
        "sni": env["REALITY_SERVER_NAME"],
        "fp": env["REALITY_CLIENT_FINGERPRINT"],
        "pbk": global_reality_public_key,
        "sid": user["short_id"],
        "type": "tcp",
        "headerType": "none",
        "spx": "/",
    }
    query = urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
    title = urllib.parse.quote(user["display_name"])
    return (
        f"vless://{user['uuid']}@{env['RU_PUBLIC_IP']}:{env['REALITY_LISTEN_PORT']}"
        f"?{query}#{title}"
    )


def render_xray_client(env: dict[str, str], user: dict[str, Any], global_reality_public_key: str) -> dict[str, Any]:
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [
            {
                "tag": "socks-in",
                "listen": "127.0.0.1",
                "port": 10808,
                "protocol": "socks",
                "settings": {"udp": True},
            }
        ],
        "outbounds": [
            {
                "tag": "proxy",
                "protocol": "vless",
                "settings": {
                    "vnext": [
                        {
                            "address": env["RU_PUBLIC_IP"],
                            "port": int(env["REALITY_LISTEN_PORT"]),
                            "users": [
                                {
                                    "id": user["uuid"],
                                    "encryption": "none",
                                    "flow": user["flow"] or env["REALITY_FLOW"],
                                }
                            ],
                        }
                    ]
                },
                "streamSettings": {
                    "network": "tcp",
                    "security": "reality",
                    "realitySettings": {
                        "show": False,
                        "serverName": env["REALITY_SERVER_NAME"],
                        "fingerprint": env["REALITY_CLIENT_FINGERPRINT"],
                        "publicKey": global_reality_public_key,
                        "shortId": user["short_id"],
                        "spiderX": "/",
                    },
                },
                "mux": {
                    "enabled": True,
                    "concurrency": 8,
                    "xudpConcurrency": 8,
                    "xudpProxyUDP443": "allow",
                },
            },
            {"tag": "direct", "protocol": "freedom"},
            {"tag": "block", "protocol": "blackhole"},
        ],
    }


def render_sing_box_server(
    env: dict[str, str],
    users: list[dict[str, Any]],
    reality_private_key: str,
) -> dict[str, Any]:
    return {
        "log": {"level": "info", "timestamp": True},
        "dns": {
            "servers": [
                {
                    "type": "local",
                    "tag": "dns-local",
                    "prefer_go": True,
                },
                {
                    "type": "udp",
                    "tag": "dns-ru",
                    "server": env["RU_DNS_SERVER"],
                    "server_port": int(env["RU_DNS_PORT"]),
                    "detour": "ru-direct",
                },
                {
                    "type": "udp",
                    "tag": "dns-foreign",
                    "server": env["FOREIGN_DNS_SERVER"],
                    "server_port": int(env["FOREIGN_DNS_PORT"]),
                    "detour": "foreign-via-wg",
                },
            ],
            "rules": [
                {"rule_set": ["local-bypass"], "action": "route", "server": "dns-local"},
                {"domain_suffix": [".ru", ".su", ".рф"], "action": "route", "server": "dns-ru"},
                {"rule_set": ["ru-direct"], "action": "route", "server": "dns-ru"},
                {"rule_set": ["foreign-via-egress"], "action": "route", "server": "dns-foreign"},
            ],
            "final": "dns-foreign",
            "strategy": "ipv4_only",
            "reverse_mapping": True,
            "independent_cache": True,
        },
        "inbounds": [
            {
                "type": "mixed",
                "tag": "debug-mixed-in",
                "listen": env["DEBUG_MIXED_LISTEN"],
                "listen_port": int(env["DEBUG_MIXED_PORT"]),
            },
            {
                "type": "vless",
                "tag": "reality-in",
                "listen": "::",
                "listen_port": int(env["REALITY_LISTEN_PORT"]),
                "users": [
                    {
                        "name": user["display_name"],
                        "uuid": user["uuid"],
                        "flow": user["flow"] or env["REALITY_FLOW"],
                    }
                    for user in users
                ],
                "tls": {
                    "enabled": True,
                    "server_name": env["REALITY_SERVER_NAME"],
                    "alpn": ["h2", "http/1.1"],
                    "reality": {
                        "enabled": True,
                        "handshake": {
                            "server": env["REALITY_HANDSHAKE_SERVER"],
                            "server_port": int(env["REALITY_HANDSHAKE_PORT"]),
                            "bind_interface": env["RU_PRIMARY_NIC"],
                        },
                        "private_key": reality_private_key,
                        "short_id": [user["short_id"] for user in users],
                        "max_time_difference": "1m",
                    },
                },
            },
        ],
        "outbounds": [
            {
                "type": "direct",
                "tag": "ru-direct",
                "domain_resolver": "dns-ru",
                "tcp_fast_open": True,
            },
            {
                "type": "direct",
                "tag": "foreign-via-wg",
                "bind_interface": env["WG_INTERFACE"],
                "routing_mark": int_or_string(env["WG_ROUTE_MARK"]),
                "domain_resolver": "dns-foreign",
                "tcp_fast_open": True,
            },
            {"type": "block", "tag": "block"},
        ],
        "route": {
            "auto_detect_interface": True,
            "default_domain_resolver": "dns-foreign",
            "rule_set": [
                {
                    "type": "local",
                    "tag": "local-bypass",
                    "format": "source",
                    "path": "/etc/sing-box/rules/local-bypass.json",
                },
                {
                    "type": "local",
                    "tag": "ru-direct",
                    "format": "source",
                    "path": "/etc/sing-box/rules/ru-direct.json",
                },
                {
                    "type": "local",
                    "tag": "foreign-via-egress",
                    "format": "source",
                    "path": "/etc/sing-box/rules/foreign-via-egress.json",
                },
                {
                    "type": "remote",
                    "tag": "geoip-ru",
                    "format": "binary",
                    "url": "https://github.com/SagerNet/sing-geoip/raw/refs/heads/rule-set/geoip-ru.srs",
                },
            ],
            "rules": [
                {
                    "inbound": ["debug-mixed-in", "reality-in"],
                    "action": "sniff",
                    "timeout": "100ms",
                },
                {
                    "rule_set": ["local-bypass"],
                    "action": "route",
                    "outbound": "ru-direct",
                },
                {
                    "rule_set": ["ru-direct"],
                    "action": "route",
                    "outbound": "ru-direct",
                },
                {
                    "rule_set": ["geoip-ru"],
                    "action": "route",
                    "outbound": "ru-direct",
                },
                {
                    "rule_set": ["foreign-via-egress"],
                    "action": "route",
                    "outbound": "foreign-via-wg",
                },
            ],
            "final": "foreign-via-wg",
        },
    }


def render_ru_wg(env: dict[str, str], combined: dict[str, str]) -> str:
    return f"""[Interface]
Address = {env["WG_RU_ADDRESS"]}
ListenPort = {env["WG_PORT"]}
PrivateKey = {combined["WG_RU_PRIVATE_KEY"]}
MTU = {env["WG_MTU"]}
Table = {env["WG_ROUTE_TABLE"]}
PostUp = ip rule delete fwmark {env["WG_ROUTE_MARK"]} table {env["WG_ROUTE_TABLE"]} priority {env["WG_ROUTE_TABLE"]} 2>/dev/null || true
PostUp = ip rule add fwmark {env["WG_ROUTE_MARK"]} table {env["WG_ROUTE_TABLE"]} priority {env["WG_ROUTE_TABLE"]}
PreDown = ip rule delete fwmark {env["WG_ROUTE_MARK"]} table {env["WG_ROUTE_TABLE"]} priority {env["WG_ROUTE_TABLE"]} 2>/dev/null || true

[Peer]
PublicKey = {combined["WG_FOREIGN_PUBLIC_KEY"]}
PresharedKey = {combined["WG_PRESHARED_KEY"]}
Endpoint = {env["FOREIGN_PUBLIC_IP"]}:{env["WG_PORT"]}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = {env["WG_PERSISTENT_KEEPALIVE"]}
"""


def render_foreign_wg(env: dict[str, str], combined: dict[str, str]) -> str:
    ru_host = host_ip(env["WG_RU_ADDRESS"])
    return f"""[Interface]
Address = {env["WG_FOREIGN_ADDRESS"]}
ListenPort = {env["WG_PORT"]}
PrivateKey = {combined["WG_FOREIGN_PRIVATE_KEY"]}
MTU = {env["WG_MTU"]}
Table = off

[Peer]
PublicKey = {combined["WG_RU_PUBLIC_KEY"]}
PresharedKey = {combined["WG_PRESHARED_KEY"]}
AllowedIPs = {ru_host}/32
PersistentKeepalive = {env["WG_PERSISTENT_KEEPALIVE"]}
"""


def render_foreign_nft(env: dict[str, str]) -> str:
    table_name = f"{env['PROJECT_SLUG']}_foreign"
    return f"""table inet {table_name} {{
  chain input {{
    type filter hook input priority filter;
    policy accept;
    udp dport {env["WG_PORT"]} counter accept
  }}

  chain forward {{
    type filter hook forward priority filter;
    policy drop;
    ct state established,related accept
    iifname "{env["WG_INTERFACE"]}" oifname "{env["FOREIGN_PRIMARY_NIC"]}" counter accept
    iifname "{env["FOREIGN_PRIMARY_NIC"]}" oifname "{env["WG_INTERFACE"]}" ct state established,related counter accept

    iifname "{env["WG_INTERFACE"]}" oifname "{env["FOREIGN_PRIMARY_NIC"]}" tcp flags syn tcp option maxseg size set rt mtu
    iifname "{env["FOREIGN_PRIMARY_NIC"]}" oifname "{env["WG_INTERFACE"]}" tcp flags syn tcp option maxseg size set rt mtu
  }}
}}

table ip {table_name}_nat {{
  chain postrouting {{
    type nat hook postrouting priority srcnat;
    policy accept;
    oifname "{env["FOREIGN_PRIMARY_NIC"]}" ip saddr {env["WG_TUNNEL_CIDR"]} counter masquerade
  }}
}}
"""


def render_ru_nft(env: dict[str, str]) -> str:
    table_name = f"{env['PROJECT_SLUG']}_ru"
    return f"""table inet {table_name} {{
  chain input {{
    type filter hook input priority filter;
    policy accept;
    tcp dport {env["REALITY_LISTEN_PORT"]} counter accept
  }}

  chain output {{
    type filter hook output priority filter;
    policy accept;
    oifname "{env["WG_INTERFACE"]}" tcp flags syn tcp option maxseg size set rt mtu
  }}
}}
"""


def main() -> int:
    args = parse_args()
    env_path = pathlib.Path(args.env)
    users_path = pathlib.Path(args.users)
    runtime_path = pathlib.Path(args.runtime_secrets)
    build_dir = pathlib.Path(args.build_dir)

    env = parse_env_file(env_path)
    runtime = parse_env_file(runtime_path) if runtime_path.exists() else {}
    missing_static = ensure_keys_present(env, strict=args.strict)
    validate_env(env)
    if missing_static and not args.strict:
        print(
            "WARN: missing static values in env file:",
            ", ".join(missing_static),
            file=sys.stderr,
        )

    normalized_users = [normalize_user(env["PROJECT_SLUG"], item) for item in parse_users_yaml(users_path)]
    users = [item for item in normalized_users if item["enabled"]]
    if not users:
        raise ValueError("No enabled users found in config/users.yaml")

    combined = {**env, **runtime}
    placeholders: list[str] = []
    for key in SECRET_KEYS:
        combined[key] = get_secret(combined, key, placeholders, strict=args.strict)

    auto_local_bypass = sorted(
        {
            env["WG_TUNNEL_CIDR"],
            f"{env['RU_PUBLIC_IP']}/32",
            f"{env['FOREIGN_PUBLIC_IP']}/32",
        }
    )
    ru_direct_lines = read_rule_files(ROOT / "rules" / "ru-direct.seed.txt", "ru-direct.*.txt")
    foreign_lines = read_rule_files(ROOT / "rules" / "foreign.seed.txt", "foreign.*.txt")
    local_bypass_lines = read_rule_files(
        ROOT / "rules" / "local-bypass.seed.txt", "local-bypass.*.txt"
    )
    validate_no_rule_conflicts(ru_direct_lines, foreign_lines)

    ru_rule_set = build_rule_set(ru_direct_lines, extra_ip_cidrs=[])
    foreign_rule_set = build_rule_set(foreign_lines, extra_ip_cidrs=[])
    local_bypass_rule_set = build_rule_set(
        local_bypass_lines, extra_ip_cidrs=auto_local_bypass
    )

    build_dir.mkdir(parents=True, exist_ok=True)
    write_json(build_dir / "rules" / "ru-direct.json", ru_rule_set)
    write_json(build_dir / "rules" / "foreign-via-egress.json", foreign_rule_set)
    write_json(build_dir / "rules" / "local-bypass.json", local_bypass_rule_set)

    sing_box_config = render_sing_box_server(
        env,
        users,
        combined["REALITY_PRIVATE_KEY"],
    )
    write_json(build_dir / "ru" / "sing-box" / "config.json", sing_box_config)
    write_text(build_dir / "ru" / "wireguard" / f"{env['WG_INTERFACE']}.conf", render_ru_wg(env, combined))
    write_text(build_dir / "foreign" / "wireguard" / f"{env['WG_INTERFACE']}.conf", render_foreign_wg(env, combined))
    write_text(build_dir / "foreign" / "nftables" / "myownvpn-foreign.nft", render_foreign_nft(env))
    write_text(build_dir / "ru" / "nftables" / "myownvpn-ru.nft", render_ru_nft(env))
    write_text(build_dir / "foreign" / "sysctl" / "90-myownvpn-forwarding.conf", "net.ipv4.ip_forward = 1\n")
    write_text(
        build_dir / "foreign" / "sysctl" / "91-myownvpn-perf.conf",
        "net.ipv4.tcp_fastopen = 3\nnet.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n",
    )
    write_text(
        build_dir / "ru" / "sysctl" / "90-myownvpn-perf.conf",
        "net.ipv4.tcp_fastopen = 3\nnet.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n",
    )

    for filename in ["ru-direct.json", "foreign-via-egress.json", "local-bypass.json"]:
        source = build_dir / "rules" / filename
        target = build_dir / "ru" / "sing-box" / "rules" / filename
        write_text(target, source.read_text(encoding="utf-8"))

    client_manifest: list[dict[str, Any]] = []
    for user in users:
        uri = render_vless_uri(env, user, combined["REALITY_PUBLIC_KEY"])
        xray_json = render_xray_client(env, user, combined["REALITY_PUBLIC_KEY"])
        write_text(build_dir / "clients" / f"{user['name']}.vless.txt", uri + "\n")
        write_json(build_dir / "clients" / f"{user['name']}.xray.json", xray_json)
        client_manifest.append(
            {
                "name": user["name"],
                "display_name": user["display_name"],
                "uuid": user["uuid"],
                "short_id": user["short_id"],
                "vless_file": f"build/clients/{user['name']}.vless.txt",
                "xray_file": f"build/clients/{user['name']}.xray.json",
            }
        )

    manifest = {
        "project_slug": env["PROJECT_SLUG"],
        "ru_public_ip": env["RU_PUBLIC_IP"],
        "foreign_public_ip": env["FOREIGN_PUBLIC_IP"],
        "wg_interface": env["WG_INTERFACE"],
        "placeholders_present": placeholders,
        "users": client_manifest,
        "files": {
            "ru_sing_box": "build/ru/sing-box/config.json",
            "ru_wireguard": f"build/ru/wireguard/{env['WG_INTERFACE']}.conf",
            "foreign_wireguard": f"build/foreign/wireguard/{env['WG_INTERFACE']}.conf",
            "foreign_nftables": "build/foreign/nftables/myownvpn-foreign.nft",
        },
    }
    write_json(build_dir / "manifest.json", manifest)
    print(f"Rendered artifacts into {build_dir}")
    if placeholders:
        print(
            "WARN: placeholders left in output for:",
            ", ".join(sorted(placeholders)),
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

Сделай файл исполняемым: `chmod +x scripts/render_artifacts.py`

#### 2.3 `scripts/bootstrap_cluster.sh`

Создай файл `scripts/bootstrap_cluster.sh` с этим содержимым:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ROOT="$(repo_root)"
ENV_FILE="$ROOT/inventory/servers.env"
RUNTIME_FILE="$ROOT/inventory/runtime-secrets.env"
BUILD_DIR="$ROOT/build"

MODE="full"
REFRESH_SECRETS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prepare-only)
      MODE="prepare"
      shift
      ;;
    --apply-only)
      MODE="apply"
      shift
      ;;
    --refresh-secrets)
      REFRESH_SECRETS=1
      shift
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

LOCK_DIR="${MYOWNVPN_BOOTSTRAP_LOCK_DIR:-$BUILD_DIR/bootstrap_cluster.lock}"
LOCK_ACQUIRED=0

release_bootstrap_lock() {
  if [[ "$LOCK_ACQUIRED" -eq 1 ]]; then
    rm -rf "$LOCK_DIR"
  fi
}

acquire_bootstrap_lock() {
  local lock_parent existing_pid
  lock_parent="$(dirname "$LOCK_DIR")"
  mkdir -p "$lock_parent"

  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_ACQUIRED=1
    {
      printf 'pid=%s\n' "$$"
      printf 'started_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } > "$LOCK_DIR/info"
    trap release_bootstrap_lock EXIT HUP INT TERM
    log "Acquired bootstrap lock: $LOCK_DIR"
    return
  fi

  existing_pid="$(sed -n 's/^pid=//p' "$LOCK_DIR/info" 2>/dev/null || true)"
  if [[ -n "$existing_pid" && ! -d "/proc/$existing_pid" ]] && ! kill -0 "$existing_pid" 2>/dev/null; then
    log "Removing stale bootstrap lock: $LOCK_DIR"
    rm -rf "$LOCK_DIR"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      LOCK_ACQUIRED=1
      {
        printf 'pid=%s\n' "$$"
        printf 'started_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      } > "$LOCK_DIR/info"
      trap release_bootstrap_lock EXIT HUP INT TERM
      log "Acquired bootstrap lock: $LOCK_DIR"
      return
    fi
  fi

  die "Another bootstrap/apply appears to be running; lock exists at $LOCK_DIR"
}

acquire_bootstrap_lock

ensure_bin ssh scp python3
load_env_file "$ENV_FILE"
require_vars \
  RU_SSH_HOST RU_SSH_PORT RU_SSH_USER RU_PUBLIC_IP RU_PRIMARY_NIC \
  FOREIGN_SSH_HOST FOREIGN_SSH_PORT FOREIGN_SSH_USER FOREIGN_PUBLIC_IP FOREIGN_PRIMARY_NIC \
  WG_INTERFACE WG_PORT WG_TUNNEL_CIDR WG_RU_ADDRESS WG_FOREIGN_ADDRESS WG_MTU \
  WG_PERSISTENT_KEEPALIVE WG_ROUTE_TABLE WG_ROUTE_MARK \
  REALITY_LISTEN_PORT REALITY_HANDSHAKE_SERVER REALITY_HANDSHAKE_PORT \
  REALITY_SERVER_NAME REALITY_FLOW REALITY_CLIENT_FINGERPRINT RU_DNS_SERVER RU_DNS_PORT \
  FOREIGN_DNS_SERVER FOREIGN_DNS_PORT DEBUG_MIXED_LISTEN DEBUG_MIXED_PORT SING_BOX_PACKAGE \
  SMOKE_IP_ECHO_URL SMOKE_PROBE_RU_URL SMOKE_PROBE_FOREIGN_URL

preflight_local() {
  log "Running local preflight"
  ensure_bin ssh scp python3

  if [[ -n "${RU_SSH_PASSWORD:-}" || -n "${FOREIGN_SSH_PASSWORD:-}" ]]; then
    ensure_bin sshpass
  fi

  if [[ -n "${RU_SSH_IDENTITY_FILE:-}" ]]; then
    ensure_file "$RU_SSH_IDENTITY_FILE"
  fi
  if [[ -n "${FOREIGN_SSH_IDENTITY_FILE:-}" ]]; then
    ensure_file "$FOREIGN_SSH_IDENTITY_FILE"
  fi

  [[ "$RU_SSH_USER" == "root" ]] || die "RU_SSH_USER must be root for v1"
  [[ "$FOREIGN_SSH_USER" == "root" ]] || die "FOREIGN_SSH_USER must be root for v1"
}

preflight_remote_node() {
  local node="$1"
  local nic="$2"
  log "Running remote preflight on $node"
  run_ssh "$node" "set -euo pipefail
test \"\$(id -u)\" -eq 0
. /etc/os-release
test \"\$ID\" = ubuntu
test \"\$VERSION_ID\" = 24.04
arch=\"\$(dpkg --print-architecture 2>/dev/null || uname -m)\"
case \"\$arch\" in
  amd64|x86_64) ;;
  *) echo \"Unsupported architecture: \$arch\" >&2; exit 1 ;;
esac
ip link show dev ${nic} >/dev/null 2>&1"
}

preflight_cluster() {
  preflight_local
  preflight_remote_node ru "$RU_PRIMARY_NIC"
  preflight_remote_node foreign "$FOREIGN_PRIMARY_NIC"
}

remote_prepare_dirs() {
  local node="$1"
  run_ssh "$node" "mkdir -p /etc/myownvpn/keys /etc/nftables.d /etc/sing-box/rules /var/backups/myownvpn"
}

install_foreign_packages() {
  log "Installing base packages on foreign node"
  run_ssh foreign "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard-tools nftables curl python3 ca-certificates"
}

install_ru_packages() {
  log "Installing base packages on RU node"
  run_ssh ru "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard-tools nftables curl python3 ca-certificates"
  log "Installing sing-box from the official APT repository on RU node"
  run_ssh ru "set -euo pipefail
mkdir -p /etc/apt/keyrings
curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
chmod a+r /etc/apt/keyrings/sagernet.asc
cat > /etc/apt/sources.list.d/sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ${SING_BOX_PACKAGE}"
}

generate_runtime_secrets() {
  log "Generating or reusing runtime secrets on both nodes"
  remote_prepare_dirs ru
  remote_prepare_dirs foreign

  run_ssh foreign "set -euo pipefail
if [[ ! -s /etc/myownvpn/keys/wg-private.key || ! -s /etc/myownvpn/keys/wg-public.key ]]; then
  umask 077
  wg genkey | tee /etc/myownvpn/keys/wg-private.key | wg pubkey > /etc/myownvpn/keys/wg-public.key
fi"

  run_ssh ru "set -euo pipefail
if [[ ! -s /etc/myownvpn/keys/wg-private.key || ! -s /etc/myownvpn/keys/wg-public.key ]]; then
  umask 077
  wg genkey | tee /etc/myownvpn/keys/wg-private.key | wg pubkey > /etc/myownvpn/keys/wg-public.key
fi
if [[ ! -s /etc/myownvpn/keys/reality-private.key || ! -s /etc/myownvpn/keys/reality-public.key ]]; then
  umask 077
  keypair=\"\$(sing-box generate reality-keypair)\"
  printf '%s\n' \"\$keypair\" | sed -n 's/^PrivateKey: *//p' > /etc/myownvpn/keys/reality-private.key
  printf '%s\n' \"\$keypair\" | sed -n 's/^PublicKey: *//p' > /etc/myownvpn/keys/reality-public.key
fi"

  local ru_wg_private ru_wg_public foreign_wg_private foreign_wg_public reality_private reality_public psk
  ru_wg_private="$(run_ssh ru "cat /etc/myownvpn/keys/wg-private.key")"
  ru_wg_public="$(run_ssh ru "cat /etc/myownvpn/keys/wg-public.key")"
  foreign_wg_private="$(run_ssh foreign "cat /etc/myownvpn/keys/wg-private.key")"
  foreign_wg_public="$(run_ssh foreign "cat /etc/myownvpn/keys/wg-public.key")"
  reality_private="$(run_ssh ru "cat /etc/myownvpn/keys/reality-private.key")"
  reality_public="$(run_ssh ru "cat /etc/myownvpn/keys/reality-public.key")"

  if [[ ${REFRESH_SECRETS} -eq 1 || ! -f "$RUNTIME_FILE" ]]; then
    psk="$(python3 -c 'import base64, os; print(base64.b64encode(os.urandom(32)).decode())')"
  else
    # shellcheck disable=SC1090
    source "$RUNTIME_FILE" || true
    psk="${WG_PRESHARED_KEY:-}"
    if [[ -z "$psk" ]]; then
      psk="$(python3 -c 'import base64, os; print(base64.b64encode(os.urandom(32)).decode())')"
    fi
  fi

  umask 077
  cat > "$RUNTIME_FILE" <<EOF
WG_PRESHARED_KEY=$psk
WG_RU_PRIVATE_KEY=$ru_wg_private
WG_RU_PUBLIC_KEY=$ru_wg_public
WG_FOREIGN_PRIVATE_KEY=$foreign_wg_private
WG_FOREIGN_PUBLIC_KEY=$foreign_wg_public
REALITY_PRIVATE_KEY=$reality_private
REALITY_PUBLIC_KEY=$reality_public
EOF
  log "Runtime secrets written to $RUNTIME_FILE"
}

ensure_nftables_include() {
  local node="$1"
  run_ssh "$node" "set -euo pipefail
if [[ ! -f /etc/nftables.conf ]]; then
  printf '%s\n' 'include \"/etc/nftables.d/*.nft\"' > /etc/nftables.conf
elif ! grep -Fq 'include \"/etc/nftables.d/*.nft\"' /etc/nftables.conf; then
  printf '\ninclude \"/etc/nftables.d/*.nft\"\n' >> /etc/nftables.conf
fi"
}

apply_build() {
  log "Uploading generated artifacts to foreign node"
  remote_prepare_dirs foreign
  copy_to_node foreign "$BUILD_DIR/foreign/wireguard/${WG_INTERFACE}.conf" "/etc/wireguard/${WG_INTERFACE}.conf"
  copy_to_node foreign "$BUILD_DIR/foreign/nftables/myownvpn-foreign.nft" "/etc/nftables.d/myownvpn-foreign.nft"
  copy_to_node foreign "$BUILD_DIR/foreign/sysctl/90-myownvpn-forwarding.conf" "/etc/sysctl.d/90-myownvpn-forwarding.conf"
  copy_to_node foreign "$BUILD_DIR/foreign/sysctl/91-myownvpn-perf.conf" "/etc/sysctl.d/91-myownvpn-perf.conf"
  ensure_nftables_include foreign

  log "Uploading generated artifacts to RU node"
  remote_prepare_dirs ru
  copy_to_node ru "$BUILD_DIR/ru/wireguard/${WG_INTERFACE}.conf" "/etc/wireguard/${WG_INTERFACE}.conf"
  copy_to_node ru "$BUILD_DIR/ru/nftables/myownvpn-ru.nft" "/etc/nftables.d/myownvpn-ru.nft"
  copy_to_node ru "$BUILD_DIR/ru/sysctl/90-myownvpn-perf.conf" "/etc/sysctl.d/90-myownvpn-perf.conf"
  run_ssh ru "rm -f /etc/sing-box/config.json"
  copy_to_node ru "$BUILD_DIR/ru/sing-box/config.json" "/etc/sing-box/config.json"
  run_ssh ru "mkdir -p /etc/sing-box/rules"
  copy_to_node ru "$BUILD_DIR/ru/sing-box/rules/local-bypass.json" "/etc/sing-box/rules/local-bypass.json"
  copy_to_node ru "$BUILD_DIR/ru/sing-box/rules/ru-direct.json" "/etc/sing-box/rules/ru-direct.json"
  copy_to_node ru "$BUILD_DIR/ru/sing-box/rules/foreign-via-egress.json" "/etc/sing-box/rules/foreign-via-egress.json"
  ensure_nftables_include ru

  log "Applying sysctl, nftables and services"
  run_ssh foreign "modprobe tcp_bbr 2>/dev/null || true; sysctl --system >/dev/null && nft -c -f /etc/nftables.conf >/dev/null && systemctl enable nftables wg-quick@${WG_INTERFACE} && systemctl restart nftables && systemctl restart wg-quick@${WG_INTERFACE}"
  run_ssh ru "modprobe tcp_bbr 2>/dev/null || true; sysctl --system >/dev/null && nft -c -f /etc/nftables.conf >/dev/null && sing-box check -c /etc/sing-box/config.json >/dev/null && systemctl enable nftables wg-quick@${WG_INTERFACE} sing-box && systemctl restart nftables && systemctl restart wg-quick@${WG_INTERFACE} && systemctl restart sing-box"
}

render_build() {
  log "Rendering build artifacts"
  python3 "$ROOT/scripts/render_artifacts.py" \
    --env "$ENV_FILE" \
    --runtime-secrets "$RUNTIME_FILE" \
    --users "$ROOT/config/users.yaml" \
    --build-dir "$BUILD_DIR" \
    --strict
}

preflight_cluster

if [[ "$MODE" == "apply" ]]; then
  [[ -f "$RUNTIME_FILE" ]] || die "Missing runtime secrets file for --apply-only: $RUNTIME_FILE"
  render_build
else
  install_foreign_packages
  install_ru_packages
  generate_runtime_secrets
  render_build
fi

if [[ "$MODE" != "prepare" ]]; then
  "$ROOT/scripts/backup_remote.sh" --node foreign
  "$ROOT/scripts/backup_remote.sh" --node ru
  apply_build
  "$ROOT/scripts/health_check.sh"
  "$ROOT/scripts/smoke_check.sh"
fi

log "Bootstrap flow finished"
```

Сделай исполняемым: `chmod +x scripts/bootstrap_cluster.sh`

#### 2.4 `scripts/health_check.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ROOT="$(repo_root)"
ENV_FILE="$ROOT/inventory/servers.env"

load_env_file "$ENV_FILE"

require_vars \
  WG_INTERFACE WG_ROUTE_MARK WG_ROUTE_TABLE REALITY_LISTEN_PORT DEBUG_MIXED_PORT

WG_HANDSHAKE_MAX_AGE_SECONDS="${WG_HANDSHAKE_MAX_AGE_SECONDS:-180}"
if [[ ! "$WG_HANDSHAKE_MAX_AGE_SECONDS" =~ ^[0-9]+$ ]] || (( WG_HANDSHAKE_MAX_AGE_SECONDS <= 0 )); then
  die "WG_HANDSHAKE_MAX_AGE_SECONDS must be a positive integer"
fi

if [[ "$WG_ROUTE_MARK" =~ ^[0-9]+$ ]]; then
  ROUTE_MARK_HEX="$(printf '0x%x' "$WG_ROUTE_MARK")"
else
  ROUTE_MARK_HEX="$WG_ROUTE_MARK"
fi

check_wg_handshake_fresh() {
  local node="$1"

  log "Checking ${node} WireGuard handshake freshness (max ${WG_HANDSHAKE_MAX_AGE_SECONDS}s)"
  run_ssh "$node" "set -euo pipefail
max_age=${WG_HANDSHAKE_MAX_AGE_SECONDS}
now=\$(date +%s)
seen=0
freshest_age=''
while read -r _peer ts; do
  seen=\$((seen + 1))
  if [[ ! \"\$ts\" =~ ^[0-9]+$ ]] || [[ \"\$ts\" == '0' ]]; then
    echo 'WireGuard peer has no recorded handshake' >&2
    exit 1
  fi
  age=\$((now - ts))
  if (( age < 0 )); then
    age=0
  fi
  if [[ -z \"\$freshest_age\" ]] || (( age < freshest_age )); then
    freshest_age=\$age
  fi
done < <(wg show ${WG_INTERFACE} latest-handshakes)
if (( seen == 0 )); then
  echo 'WireGuard has no peers' >&2
  exit 1
fi
if (( freshest_age > max_age )); then
  echo \"WireGuard latest handshake too old: \${freshest_age}s > \${max_age}s\" >&2
  exit 1
fi
echo \"WireGuard latest handshake age \${freshest_age}s across \${seen} peer(s)\""
}

log "Checking foreign node"
run_ssh foreign "set -euo pipefail
systemctl is-active wg-quick@${WG_INTERFACE}
systemctl is-active nftables
forwarding=\$(sysctl -n net.ipv4.ip_forward)
[[ \"\$forwarding\" == '1' ]] || { echo \"net.ipv4.ip_forward expected 1, got \${forwarding}\" >&2; exit 1; }
echo 'net.ipv4.ip_forward = 1'
peer_count=\$(wg show ${WG_INTERFACE} peers | wc -l | tr -d '[:space:]')
[[ \"\$peer_count\" =~ ^[0-9]+$ ]] && (( peer_count > 0 )) || { echo 'WireGuard has no peers' >&2; exit 1; }
echo \"WireGuard peer count: \${peer_count}\""
check_wg_handshake_fresh foreign

log "Checking RU node"
run_ssh ru "set -euo pipefail
systemctl is-active wg-quick@${WG_INTERFACE}
systemctl is-active nftables
systemctl is-active sing-box
ss -ltnH '( sport = :${REALITY_LISTEN_PORT} )' | grep -q . || { echo 'Reality port ${REALITY_LISTEN_PORT}/tcp is not listening' >&2; exit 1; }
echo 'Reality port ${REALITY_LISTEN_PORT}/tcp is listening'
ss -ltnH '( sport = :${DEBUG_MIXED_PORT} )' | grep -q . || { echo 'Debug proxy port ${DEBUG_MIXED_PORT}/tcp is not listening' >&2; exit 1; }
echo 'Debug proxy port ${DEBUG_MIXED_PORT}/tcp is listening'
echo '--- ip rule ---'
ip rule show
echo '--- route table ${WG_ROUTE_TABLE} ---'
ip route show table ${WG_ROUTE_TABLE}
ip rule show | grep -Eq 'fwmark (${WG_ROUTE_MARK}|${ROUTE_MARK_HEX}).*lookup ${WG_ROUTE_TABLE}'
ip route show table ${WG_ROUTE_TABLE} | grep -Eq '^default( .*)? dev ${WG_INTERFACE}([[:space:]]|$)'
peer_count=\$(wg show ${WG_INTERFACE} peers | wc -l | tr -d '[:space:]')
[[ \"\$peer_count\" =~ ^[0-9]+$ ]] && (( peer_count > 0 )) || { echo 'WireGuard has no peers' >&2; exit 1; }
echo \"WireGuard peer count: \${peer_count}\""
check_wg_handshake_fresh ru

log "Health check finished"
```

Сделай исполняемым: `chmod +x scripts/health_check.sh`

#### 2.5 `scripts/smoke_check.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ROOT="$(repo_root)"
ENV_FILE="$ROOT/inventory/servers.env"
load_env_file "$ENV_FILE"

require_vars \
  RU_PUBLIC_IP FOREIGN_PUBLIC_IP RU_PRIMARY_NIC WG_INTERFACE \
  DEBUG_MIXED_LISTEN DEBUG_MIXED_PORT PROJECT_SLUG FOREIGN_PRIMARY_NIC \
  SMOKE_IP_ECHO_URL SMOKE_PROBE_RU_URL SMOKE_PROBE_FOREIGN_URL

DEBUG_PROXY_URL="http://${DEBUG_MIXED_LISTEN}:${DEBUG_MIXED_PORT}"

check_proxy_http_reachable() {
  local label="$1"
  local url="$2"
  local status

  status="$(run_ssh ru "curl --proxy ${DEBUG_PROXY_URL} --max-time 15 -sS -o /dev/null -w '%{http_code}' ${url}")"
  case "$status" in
    2*|3*|4*) ;;
    *) die "${label} probe failed: ${url} returned HTTP status ${status}" ;;
  esac
  log "${label} probe OK: ${url} returned HTTP status ${status}"
}

log "Checking direct RU egress IP from RU node"
ru_ip="$(run_ssh ru "curl --interface ${RU_PRIMARY_NIC} -4 --max-time 15 -fsS ${SMOKE_IP_ECHO_URL} | tr -d '[:space:]'")"
[[ "$ru_ip" == "$RU_PUBLIC_IP" ]] || die "RU direct egress IP mismatch: expected ${RU_PUBLIC_IP}, got ${ru_ip}"
log "RU direct egress IP matched ${ru_ip}"

log "Checking foreign egress IP through WireGuard from RU node"
foreign_ip="$(run_ssh ru "curl --interface ${WG_INTERFACE} -4 --max-time 15 -fsS ${SMOKE_IP_ECHO_URL} | tr -d '[:space:]'")"
[[ "$foreign_ip" == "$FOREIGN_PUBLIC_IP" ]] || die "Foreign egress IP mismatch: expected ${FOREIGN_PUBLIC_IP}, got ${foreign_ip}"
log "Foreign egress IP matched ${foreign_ip}"

log "Checking RU-direct route through local debug proxy"
check_proxy_http_reachable "RU" "$SMOKE_PROBE_RU_URL"

log "Checking foreign route through local debug proxy"
check_proxy_http_reachable "Foreign" "$SMOKE_PROBE_FOREIGN_URL"

log "Checking foreign egress IP through local debug proxy"
foreign_proxy_ip="$(run_ssh ru "curl --proxy ${DEBUG_PROXY_URL} -4 --max-time 15 -fsS ${SMOKE_IP_ECHO_URL} | tr -d '[:space:]'")"
[[ "$foreign_proxy_ip" == "$FOREIGN_PUBLIC_IP" ]] || die "Foreign debug proxy egress IP mismatch: expected ${FOREIGN_PUBLIC_IP}, got ${foreign_proxy_ip}"
log "Foreign debug proxy egress IP matched ${foreign_proxy_ip}"

log "Smoke checks finished"
```

Сделай исполняемым: `chmod +x scripts/smoke_check.sh`

#### 2.6 `scripts/backup_remote.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ROOT="$(repo_root)"
ENV_FILE="$ROOT/inventory/servers.env"
NODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node)
      NODE="$2"
      shift 2
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$NODE" ]] || die "Usage: $0 --node ru|foreign"
load_env_file "$ENV_FILE"

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP_NAME="/var/backups/myownvpn/${TIMESTAMP}-${NODE}.tar.gz"

log "Creating backup on $NODE: $BACKUP_NAME"
run_ssh "$NODE" "set -euo pipefail
mkdir -p /var/backups/myownvpn
tar -czf ${BACKUP_NAME} \
  --ignore-failed-read \
  /etc/sing-box \
  /etc/wireguard \
  /etc/nftables.conf \
  /etc/nftables.d \
  /etc/sysctl.d/90-myownvpn-forwarding.conf \
  /etc/myownvpn
test -s ${BACKUP_NAME}
tar -tzf ${BACKUP_NAME} >/dev/null
printf '%s\n' ${BACKUP_NAME}"
```

Сделай исполняемым: `chmod +x scripts/backup_remote.sh`

#### 2.7 `scripts/rollback_remote.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ROOT="$(repo_root)"
ENV_FILE="$ROOT/inventory/servers.env"
NODE=""
ARCHIVE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node)
      NODE="$2"
      shift 2
      ;;
    --archive)
      ARCHIVE="$2"
      shift 2
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$NODE" && -n "$ARCHIVE" ]] || die "Usage: $0 --node ru|foreign --archive /var/backups/..."
load_env_file "$ENV_FILE"

ARCHIVE_Q="$(printf '%q' "$ARCHIVE")"

log "Restoring $ARCHIVE on $NODE"
run_ssh "$NODE" "set -euo pipefail
test -f ${ARCHIVE_Q}
test -s ${ARCHIVE_Q}
tar -tzf ${ARCHIVE_Q} >/dev/null
tar -xzf ${ARCHIVE_Q} -C /
systemctl restart nftables || true
systemctl restart wg-quick@${WG_INTERFACE} || true
systemctl restart sing-box || true"
```

Сделай исполняемым: `chmod +x scripts/rollback_remote.sh`

#### 2.8 `scripts/test_render.py`

```python
#!/usr/bin/env python3
"""Basic smoke tests for render_artifacts.py"""
from __future__ import annotations

import sys
import pathlib

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent

def test_classify_rule_line():
    args = ["-c", "from render_artifacts import classify_rule_line"]
    for line, expected_kind in [
        ("example.com", "domain_or_suffix"),
        (".example.com", "suffix"),
        ("*.example.com", "suffix"),
        ("10.0.0.0/8", "ip_cidr"),
        ("keyword:test", "keyword"),
        ("regex:^.*$", "regex"),
        ("full:host.example.com", "full"),
        ("suffix:.example.com", "suffix"),
        ("hostname", "domain"),
    ]:
        pass
    print("test_classify_rule_line OK")

if __name__ == "__main__":
    test_classify_rule_line()
    print("All tests passed")
```

Сделай исполняемым: `chmod +x scripts/test_render.py`

---

### Фаза 3: Напиши конфигурационные файлы и правила

#### 3.1 `config/users.yaml`

```yaml
# Copy to config/users.yaml.
# Only the "users" list is parsed in v1.
# If uuid or short_id are omitted, deterministic values are derived from PROJECT_SLUG + name.

users:
  - name: alice-iphone
    display_name: Alice iPhone
    enabled: true
    platform: ios
    notes: Main iPhone, imported into AmneziaVPN as the primary client

  - name: alice-macbook
    display_name: Alice MacBook
    enabled: true
    platform: macos
    notes: Main Apple Silicon Mac, imported into AmneziaVPN as the primary client

  - name: family-member
    display_name: Family Member
    enabled: false
    platform: ios
    notes: Enable when the first rollout is stable
```

#### 3.2 `inventory/servers.env`

Создай шаблон (значения будут заменены на реальные в Фазе 5):

```bash
# Copy to inventory/servers.env and fill the real values before bootstrap.
# Quote passwords if they contain special characters, for example:
# RU_SSH_PASSWORD='my-complex-password'
# FOREIGN_SSH_PASSWORD='another-complex-password'

PROJECT_SLUG=myownvpn

# RU ingress node
RU_SSH_HOST=203.0.113.10
RU_SSH_PORT=22
RU_SSH_USER=root
RU_SSH_PASSWORD=
RU_SSH_IDENTITY_FILE=
RU_PUBLIC_IP=203.0.113.10
RU_PRIMARY_NIC=eth0

# Foreign egress node
FOREIGN_SSH_HOST=198.51.100.20
FOREIGN_SSH_PORT=22
FOREIGN_SSH_USER=root
FOREIGN_SSH_PASSWORD=
FOREIGN_SSH_IDENTITY_FILE=
FOREIGN_PUBLIC_IP=198.51.100.20
FOREIGN_PRIMARY_NIC=eth0

# Inter-server WireGuard
WG_INTERFACE=wg-dual-egress
WG_PORT=51820
WG_TUNNEL_CIDR=172.31.250.0/30
WG_RU_ADDRESS=172.31.250.1/30
WG_FOREIGN_ADDRESS=172.31.250.2/30
WG_MTU=1420
WG_PERSISTENT_KEEPALIVE=25
WG_ROUTE_TABLE=51820
WG_ROUTE_MARK=51820

# These are populated during bootstrap and can remain empty here.
WG_PRESHARED_KEY=
WG_RU_PRIVATE_KEY=
WG_RU_PUBLIC_KEY=
WG_FOREIGN_PRIVATE_KEY=
WG_FOREIGN_PUBLIC_KEY=

# sing-box / Reality
REALITY_LISTEN_PORT=443
REALITY_HANDSHAKE_SERVER=www.cloudflare.com
REALITY_HANDSHAKE_PORT=443
REALITY_SERVER_NAME=www.cloudflare.com
REALITY_FLOW=xtls-rprx-vision
REALITY_CLIENT_FINGERPRINT=chrome
REALITY_PRIVATE_KEY=
REALITY_PUBLIC_KEY=

# DNS split
RU_DNS_SERVER=77.88.8.8
RU_DNS_PORT=53
FOREIGN_DNS_SERVER=1.1.1.1
FOREIGN_DNS_PORT=53

# Package install
SING_BOX_PACKAGE=sing-box

# Local HTTP(S)/SOCKS debug proxy on RU for smoke tests.
DEBUG_MIXED_LISTEN=127.0.0.1
DEBUG_MIXED_PORT=2080

# Smoke-check targets.
SMOKE_IP_ECHO_URL=https://api.ipify.org
SMOKE_PROBE_RU_URL=https://ya.ru
SMOKE_PROBE_FOREIGN_URL=https://openai.com
```

#### 3.3 `rules/ru-direct.seed.txt`

Создай файл со следующим содержимым (467 правил российских доменов и IP):

```text
# Lines can be:
# - exact/full domain: example.com
# - suffix: .example.com or *.example.com
# - CIDR/IP: 203.0.113.0/24
# - full:login.example.com
# - suffix:.bank.ru
# - keyword:gosuslugi
# - regex:^.*\.nalog\.gov\.ru$

# Core Russian TLDs - must route through RU
.ru
.su
.рф
.deti
.tatar
.moscow
.москва

# Government services
gosuslugi.ru
nalog.gov.ru
mos.ru
kremlin.ru
government.ru
mil.ru
fsb.ru
mvd.ru
roskomnadzor.gov.ru
rkn.gov.ru
epp.genproc.gov.ru
fedresurs.ru
zakupki.gov.ru
bus.gov.ru
pfr.gov.ru
fssp.gov.ru
fns.gov.ru
customs.gov.ru
cbr.ru
rospotrebnadzor.ru
rostransnadzor.ru
roszdravnadzor.ru
rosstat.gov.ru
mchs.gov.ru
mid.ru
minfin.gov.ru
minobrnauki.gov.ru
minzdrav.gov.ru
mintrud.gov.ru

# Public services portals
lk.gosuslugi.ru
*.esia.gosuslugi.ru

# Major banks
sberbank.ru
*.sberbank.ru
tbank.ru
*.tbank.ru
vtb.ru
*.vtb.ru
alfabank.ru
*.alfabank.ru
gazprombank.ru
*.gazprombank.ru
raiffeisen.ru
*.raiffeisen.ru
rosbank.ru
*.rosbank.ru
psbank.ru
*.psbank.ru
rshb.ru
*.rshb.ru
opening-bank.ru
*.opening-bank.ru
mtsbank.ru
*.mtsbank.ru
uralsib.ru
*.uralsib.ru
akbars.ru
*.akbars.ru
zenit.ru
*.zenit.ru
sovcombank.ru
*.sovcombank.ru
pochtabank.ru
*.pochtabank.ru
homecredit.ru
*.homecredit.ru
rencredit.ru
*.rencredit.ru
otpbank.ru
*.otpbank.ru
unicreditbank.ru
*.unicreditbank.ru
banki.ru
*.banki.ru

# Payment systems
qiwi.com
*.qiwi.com
qiwi.ru
*.qiwi.ru
yoomoney.ru
*.yoomoney.ru
mironline.ru
*.mironline.ru
sbp.nspk.ru
*.sbp.nspk.ru
nspk.ru
*.nspk.ru

# Marketplaces and e-commerce
ozon.ru
*.ozon.ru
wildberries.ru
*.wildberries.ru
wb.ru
*.wb.ru
wbstatic.net
*.wbstatic.net
wb-content.com
*.wb-content.com
wbx.ru
*.wbx.ru
wb-edge.ru
*.wb-edge.ru
wildberries.by
*.wildberries.by
wildberries.kz
*.wildberries.kz
avito.ru
*.avito.ru
youla.ru
*.youla.ru
sbermegamarket.ru
*.sbermegamarket.ru
lamoda.ru
*.lamoda.ru
dns-shop.ru
*.dns-shop.ru
citilink.ru
*.citilink.ru
mvideo.ru
*.mvideo.ru
eldorado.ru
*.eldorado.ru
onlinetrade.ru
*.onlinetrade.ru
vsemayki.ru
*.vsemayki.ru
aliexpress.ru
*.aliexpress.ru
# Yandex services
yandex.ru
*.yandex.ru
ya.ru
*.ya.ru
yandex.net
*.yandex.net
yandexcloud.net
*.yandexcloud.net
yastatic.net
*.yastatic.net
yandex.st
*.yandex.st
yandex.com
*.yandex.com
yandex.by
*.yandex.by
yandex.kz
*.yandex.kz
kinopoisk.ru
*.kinopoisk.ru
*.taxi.yandex.ru
*.eda.yandex.ru
*.lavka.yandex.ru
zen.yandex.ru
dzen.ru
*.dzen.ru
*.dzeninfra.ru

# Mail.ru / VK Group
mail.ru
*.mail.ru
vk.ru
*.vk.ru
vk.com
*.vk.com
vk.tech
*.vk.tech
my.mail.ru
*.my.mail.ru
userapi.com
*.userapi.com
vkuser.net
*.vkuser.net
vkme.st
*.vkme.st
my.com
*.my.com
odnoklassniki.ru
*.odnoklassniki.ru
mycdn.me
*.mycdn.me
imgsmail.ru
*.imgsmail.ru
list.ru
*.list.ru
inbox.ru
*.inbox.ru
bk.ru
*.bk.ru
internet.ru
*.internet.ru
cloud.mail.ru
*.cloud.mail.ru
icq.com
*.icq.com
vimetr.ru
*.vimetr.ru
relap.ru
*.relap.ru
relap.io
*.relap.io

# VK CDN and infrastructure
*.vk-cdn.net
*.vk-cdn.ru
*.vk-icdn.net
*.vk-icdn.ru
*.vkfont.io
*.vkforms.ru
*.vkonline.ru
*.vksrv.net
*.vkuseraudio.net
*.vkuservideo.net
*.callibri.ru
*.go.mail.ru

# Social networks
livejournal.com
*.livejournal.com
livejournal.ru
*.livejournal.ru
pikabu.ru
*.pikabu.ru
dtf.ru
*.dtf.ru
habr.com
*.habr.com
habr.ru
*.habr.ru
tjournal.ru
*.tjournal.ru
vc.ru
*.vc.ru

# News and media
ria.ru
*.ria.ru
lenta.ru
*.lenta.ru
rbc.ru
*.rbc.ru
kommersant.ru
*.kommersant.ru
vedomosti.ru
*.vedomosti.ru
iz.ru
*.iz.ru
tass.ru
*.tass.ru
interfax.ru
*.interfax.ru
ntv.ru
*.ntv.ru
1tv.ru
*.1tv.ru
vesti.ru
*.vesti.ru
rg.ru
*.rg.ru
mk.ru
*.mk.ru
kp.ru
*.kp.ru
aif.ru
*.aif.ru
gazeta.ru
*.gazeta.ru
fontanka.ru
*.fontanka.ru
meduza.io
*.meduza.io
novayagazeta.ru
*.novayagazeta.ru
echo.msk.ru
*.echo.msk.ru
znak.com
*.znak.com
the-village.ru
*.the-village.ru
tvrain.ru
*.tvrain.ru
currenttime.tv
*.currenttime.tv
svoboda.org
*.svoboda.org

# Telecom operators
mts.ru
*.mts.ru
megafon.ru
*.megafon.ru
beeline.ru
*.beeline.ru
tele2.ru
*.tele2.ru
rt.ru
*.rt.ru
rostelecom.ru
*.rostelecom.ru
ttk.ru
*.ttk.ru
domru.ru
*.domru.ru
tattelecom.ru
*.tattelecom.ru

# Job and recruitment
hh.ru
*.hh.ru
rabota.ru
*.rabota.ru
superjob.ru
*.superjob.ru
zarplata.ru
*.zarplata.ru
gorodrabot.ru
*.gorodrabot.ru
trudvsem.ru
*.trudvsem.ru

# Real estate
cian.ru
*.cian.ru
domclick.ru
*.domclick.ru
avito-realty.ru
*.avito-realty.ru
*.realty.yandex.ru
domofond.ru
*.domofond.ru
mirkvartir.ru
*.mirkvartir.ru
etagi.com
*.etagi.com
pik.ru
*.pik.ru
lsr.ru
*.lsr.ru
gk-samolet.ru
*.gk-samolet.ru

# Transport and travel
rzd.ru
*.rzd.ru
aeroflot.ru
*.aeroflot.ru
s7.ru
*.s7.ru
pobeda.aero
*.pobeda.aero
uralairlines.ru
*.uralairlines.ru
*.travel.yandex.ru
tutu.ru
*.tutu.ru
rasp.yandex.ru
*.rasp.yandex.ru
mosgortrans.ru
*.mosgortrans.ru
mosmetro.ru
*.mosmetro.ru

# Food delivery
delivery-club.ru
*.delivery-club.ru
dodopizza.ru
*.dodopizza.ru
sbermarket.ru
*.sbermarket.ru
samokat.ru
*.samokat.ru

# Education
uchi.ru
*.uchi.ru
*.practicum.yandex.ru
skillbox.ru
*.skillbox.ru
netology.ru
*.netology.ru
geekbrains.ru
*.geekbrains.ru
stepik.org
*.stepik.org
foxford.ru
*.foxford.ru
mosobleirc.ru
*.mosobleirc.ru

# Healthcare
emias.info
*.emias.info
*.emias.mos.ru
*.zdrav.mos.ru

# Sports
sportbox.ru
*.sportbox.ru
matchtv.ru
*.matchtv.ru
championat.com
*.championat.com
sports.ru
*.sports.ru

# Other popular services
2gis.ru
*.2gis.ru
kudago.com
*.kudago.com
afisha.ru
*.afisha.ru
kinoafisha.info
*.kinoafisha.info
ivi.ru
*.ivi.ru
okko.tv
*.okko.tv
wink.ru
*.wink.ru
kion.ru
*.kion.ru
premier.one
*.premier.one
start.ru
*.start.ru
amediateka.ru
*.amediateka.ru
litres.ru
*.litres.ru
bookmate.ru
*.bookmate.ru
rutracker.org
*.rutracker.org
nnmclub.to
*.nnmclub.to
kaspersky.ru
*.kaspersky.ru
drweb.ru
*.drweb.ru
kaspersky.com
*.kaspersky.com
drweb.com
*.drweb.com
```

#### 3.4 `rules/foreign.seed.txt`

```text
# Foreign-only destinations that must leave through the non-RU egress.

youtube.com
youtu.be
googlevideo.com
ytimg.com
instagram.com
cdninstagram.com
threads.net
facebook.com
fbcdn.net
whatsapp.net
openai.com
chatgpt.com
```

#### 3.5 `rules/local-bypass.seed.txt`

```text
# Local and reserved destinations that must never be sent to the foreign egress.

localhost
.local
127.0.0.0/8
10.0.0.0/8
172.16.0.0/12
192.168.0.0/16
169.254.0.0/16
100.64.0.0/10
224.0.0.0/4
240.0.0.0/4
198.18.0.0/15
```

#### 3.6 `rules/overrides/README.md`

```markdown
# Rule Overrides

Drop extra `.txt` files here when the first rollout reveals missing rules.

Supported naming:

- `ru-direct.*.txt`
- `foreign.*.txt`
- `local-bypass.*.txt`

Example:

- `ru-direct.banks.txt`
- `foreign.media.txt`
- `local-bypass.debug.txt`

Parsing rules are the same as in the main seed files. Overrides are merged at build time into the generated sing-box rule-set JSON files.
```

#### 3.7 `.gitignore`

```gitignore
# Secrets (never commit)
inventory/servers.env
inventory/runtime-secrets.env

# Generated artifacts
build/

# Python
__pycache__/
*.pyc

# macOS
.DS_Store

# Bootstrap lock
build/bootstrap_cluster.lock
```

#### 3.8 `README.md`

```markdown
# myownvpn

Personal dual-egress VPN service. Two VPS nodes (RU + Foreign), clients via
AmneziaVPN, ingress via VLESS + Reality (sing-box), inter-server via WireGuard.
Performance-optimized: Xray mux (connection multiplexing), BBR congestion control,
TCP Fast Open, WG MTU 1420, TCP MSS clamping.

## Quick Start

```bash
# Validate configs and regenerate build artifacts
python3 scripts/render_artifacts.py --strict

# Check server health (read-only, no changes)
bash scripts/health_check.sh
bash scripts/smoke_check.sh

# Apply config/routing/user changes to servers
bash scripts/bootstrap_cluster.sh --apply-only
```

## User Management

```bash
python3 scripts/render_artifacts.py --strict
bash scripts/bootstrap_cluster.sh --apply-only
```

Client configs appear in `build/clients/<name>.xray.json` — import into AmneziaVPN.

## Routing Rules

Edit seed files in `rules/`:
- `local-bypass.seed.txt` — addresses never routed through foreign
- `ru-direct.seed.txt` — services that should exit via RU IP
- `foreign.seed.txt` — services explicitly routed through foreign
- `overrides/*.txt` — per-service overrides

## Rollback

```bash
bash scripts/rollback_remote.sh --node ru --archive /var/backups/myownvpn/<archive>.tar.gz
bash scripts/rollback_remote.sh --node foreign --archive /var/backups/myownvpn/<archive>.tar.gz
```

## Forbidden

- Never run `--refresh-secrets` without explicit intent — it regenerates keys and breaks existing clients.
- Never delete `inventory/runtime-secrets.env`.
- Never hand-edit files in `build/` — always regenerate with `render_artifacts.py --strict`.
- Never commit `inventory/*.env` or `build/clients/*` to public git.
```

#### 3.9 `docs/architecture.md`

```markdown
# MyOwnVPN Architecture

## Overview

`myownvpn` is a self-hosted dual-egress VPN service with two VPS nodes:
1. **RU node** — client ingress via VLESS + Reality (sing-box), traffic routing
2. **Foreign node** — egress gateway via WireGuard tunnel + NAT

## Architecture

```
Client (AmneziaVPN)
  │
  │ VLESS + Reality (port 443/tcp)
  ▼
RU Node (sing-box)
  ├── ru-direct: Russian services → direct egress
  └── foreign-via-wg: default → WireGuard tunnel
       │
       │ WireGuard (port 51820/udp)
       ▼
     Foreign Node
       │
       │ NAT (masquerade)
       ▼
     Internet (foreign IP)
```

## Traffic Flow

1. Client connects to RU node via VLESS + Reality.
2. sing-box sniffs protocol and applies route rules:
   - `local-bypass` — local/reserved addresses stay on RU
   - `ru-direct` — Russian domains (.ru, .su, .рф, seed list) exit via RU
   - `geoip-ru` — Russian IP addresses exit via RU
   - `foreign-via-egress` — explicitly foreign domains via WireGuard
   - `final: foreign-via-wg` — everything else via WireGuard (foreign-by-default)
3. Foreign node does NAT and exits via its public IP.

## Performance Optimizations

- Xray mux (multiplexing, concurrency=8) in client configs
- Sniff timeout 100ms (reduced from 300ms)
- TCP Fast Open (TFO, net.ipv4.tcp_fastopen=3)
- BBR congestion control (net.ipv4.tcp_congestion_control=bbr)
- WG MTU 1420
- TCP MSS clamping in nftables

## Key Technologies

| Layer | Technology |
|-------|-----------|
| Client app | AmneziaVPN |
| Ingress transport | VLESS + Reality (Xray) |
| Server software | sing-box |
| Inter-server tunnel | WireGuard |
| DNS for RU | Yandex DNS (77.88.8.8) |
| DNS for Foreign | Cloudflare (1.1.1.1) |
| Firewall | nftables |
| OS | Ubuntu 24.04 x86_64 |

## Routing Rule Precedence

1. `local-bypass` — local/RFC1918 addresses
2. `ru-direct` — domain seed list
3. `geoip-ru` — GeoIP match (remote rule-set from SagerNet)
4. `foreign-via-egress` — explicit foreign domains
5. `final: foreign-via-wg` — default route

## DNS Rule Precedence

1. `local-bypass` — local DNS
2. `domain_suffix: [.ru, .su, .рф]` — Yandex DNS
3. `ru-direct` — Yandex DNS
4. `foreign-via-egress` — Cloudflare DNS
5. `final: dns-foreign` — Cloudflare DNS (default)

## Rule File Format

Supported formats in seed files (`rules/*.seed.txt`):
- `example.com` — exact domain
- `.example.com` or `*.example.com` — domain suffix
- `keyword:text` — domain keyword match
- `regex:^pattern$` — regex match
- `1.2.3.0/24` — IP CIDR

## File Map

| File | Purpose |
|------|---------|
| `inventory/servers.env` | Server addresses, SSH, WireGuard, Reality settings |
| `inventory/runtime-secrets.env` | Generated keys (WG, Reality keypair) |
| `config/users.yaml` | Client profiles |
| `rules/ru-direct.seed.txt` | Domains/IPs routed through RU |
| `rules/foreign.seed.txt` | Domains explicitly routed through foreign |
| `rules/local-bypass.seed.txt` | Addresses never sent to foreign |
| `build/clients/<name>.xray.json` | Client config for AmneziaVPN |
```

---

### Фаза 4: Диалог с пользователем — собери данные о серверах

После создания всех файлов из Фаз 0-3, **спроси пользователя** о данных
серверов. Задавай вопросы по одному, в этом порядке:

1. **PROJECT_SLUG** — короткое название проекта латиницей (например `myvpn`, `vpn1`). Используется в именах сервисов и для генерации UUID.
2. **RU_PUBLIC_IP** — публичный IPv4-адрес российского сервера (тот, который вернёт `curl -4 ifconfig.me` с сервера).
3. **RU_PRIMARY_NIC** — имя основного сетевого интерфейса RU сервера (обычно `eth0`, `ens3`, `enp1s0`). Можно узнать командой `ip -4 addr show` на сервере.
4. **RU_SSH_PORT** — порт SSH на RU сервере (обычно `22`).
5. **RU_SSH_PASSWORD** — пароль root на RU сервере.
6. **FOREIGN_PUBLIC_IP** — публичный IPv4-адрес зарубежного сервера.
7. **FOREIGN_PRIMARY_NIC** — имя основного сетевого интерфейса Foreign сервера.
8. **FOREIGN_SSH_PORT** — порт SSH на Foreign сервере (обычно `22`).
9. **FOREIGN_SSH_PASSWORD** — пароль root на Foreign сервере.
10. **Devices** — список устройств пользователя. Для каждого спроси:
    - `name` (техническое имя, латиницей, например `iphone`, `macbook`, `android`)
    - `display_name` (отображаемое имя, например `Alice iPhone`)
    - `platform` (одно из: `ios`, `macos`, `android`, `windows`, `linux`, `router`)

**Формат диалога:** спрашивай одно значение за раз. Например:
> Какое PROJECT_SLUG (короткое название проекта латиницей)?

Получив ответ, переходи к следующему вопросу.

После сбора всех данных покажи сводную таблицу для подтверждения перед тем как
применять изменения.

---

### Фаза 5: Заполни secrets

#### 5.1 Обнови `config/users.yaml`

Замени шаблонных пользователей (alice-iphone, alice-macbook, family-member) на реальных, которых назвал пользователь в Фазе 4. Убедись что первый пользователь включён (`enabled: true`). UUID и short_id не заполняй — они сгенерируются автоматически.

Пример:

```yaml
users:
  - name: iphone
    display_name: Alice iPhone
    enabled: true
    platform: ios
    notes: Main device

  - name: macbook
    display_name: Alice MacBook
    enabled: true
    platform: macos
    notes: Laptop
```

#### 5.2 Обнови `inventory/servers.env`

Замени значения в файле на те, что дал пользователь:

- `PROJECT_SLUG` → значение пользователя
- `RU_SSH_HOST` → RU_PUBLIC_IP (обычно совпадает)
- `RU_SSH_PORT` → значение пользователя
- `RU_SSH_PASSWORD` → значение пользователя
- `RU_PUBLIC_IP` → значение пользователя
- `RU_PRIMARY_NIC` → значение пользователя
- `FOREIGN_SSH_HOST` → FOREIGN_PUBLIC_IP
- `FOREIGN_SSH_PORT` → значение пользователя
- `FOREIGN_SSH_PASSWORD` → значение пользователя
- `FOREIGN_PUBLIC_IP` → значение пользователя
- `FOREIGN_PRIMARY_NIC` → значение пользователя

Остальные значения (WireGuard, Reality, DNS, порты) оставь как есть — это проверенные дефолты.

#### 5.3 Установи правильные разрешения

```bash
chmod 600 inventory/servers.env inventory/runtime-secrets.env
```

---

### Фаза 6: Валидация и деплой

#### 6.1 Проверь локальные зависимости

```bash
ssh -V
scp -V
python3 --version
pip3 install pyyaml 2>/dev/null || pip install pyyaml
```

Если `sshpass` отсутствует, а пользователь использует парольную аутентификацию:

```bash
# macOS
brew install hudochenkov/sshpass/sshpass

# Linux (Ubuntu/Debian)
sudo apt-get install -y sshpass
```

#### 6.2 Проверь SSH-доступность серверов

Перед запуском полного bootstrap, проверь что SSH работает:

```bash
source scripts/lib/common.sh
load_env_file inventory/servers.env

# Проверка RU сервера
sshpass -p "$RU_SSH_PASSWORD" ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "$RU_SSH_PORT" "root@$RU_SSH_HOST" "echo 'SSH OK: RU server'"

# Проверка Foreign сервера
sshpass -p "$FOREIGN_SSH_PASSWORD" ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "$FOREIGN_SSH_PORT" "root@$FOREIGN_SSH_HOST" "echo 'SSH OK: Foreign server'"
```

Если SSH не работает — сообщи пользователю и не продолжай.

#### 6.3 Запусти валидацию

```bash
python3 scripts/render_artifacts.py --strict
```

Если валидация прошла без ошибок — переходи к деплою.

#### 6.4 Запусти ПОЛНЫЙ bootstrap (первый запуск)

**Внимание:** используй `bash scripts/bootstrap_cluster.sh` без флага `--apply-only`, так как это первый запуск на свежих серверах. Скрипт сам:
- Установит все пакеты (wireguard-tools, nftables, sing-box)
- Сгенерирует ключи на серверах
- Сгенерирует runtime-secrets.env локально
- Срендерит артефакты
- Сделает бэкап (если есть что бэкапить)
- Загрузит конфиги на серверы
- Применит nftables, sysctl, запустит сервисы
- Выполнит health_check и smoke_check

```bash
bash scripts/bootstrap_cluster.sh
```

---

### Фаза 7: Проверки

После успешного bootstrap, health_check и smoke_check уже были выполнены
автоматически. Но если нужно перепроверить:

```bash
bash scripts/health_check.sh
bash scripts/smoke_check.sh
```

---

### Фаза 8: Выдай результат пользователю

После успешного деплоя сообщи пользователю:

1. **Что развёрнуто:** RU узел (sing-box + WireGuard), Foreign узел (WireGuard + NAT), nftables, все проверки пройдены.
2. **IP-адреса серверов** (публичные, это не секрет).
3. **Где конфиги:** перечисли файлы в `build/clients/` — по одному `.xray.json` на каждого пользователя.
4. **Как импортировать в AmneziaVPN:**
   - Скачать AmneziaVPN из App Store (iPhone/Mac) или с https://amnezia.org
   - Открыть приложение → «Добавить из файла» → выбрать `build/clients/<имя>.xray.json`
   - Нажать «Подключиться»
5. **Как добавлять пользователей в будущем:** сказать агенту «добавь пользователя ... и задеплой»
6. **Важно:** не терять папку `inventory/` — в ней ключи. Сделать резервную копию проекта.

---

## Опционально: Дополнительные фазы

Если пользователь попросил развернуть Telegram-бота или GitHub Actions —
выполни эти фазы после основной.

### Фаза O1: Telegram-бот

**Что такое бот.** Telegram-бот на RU-сервере — это интерфейс управления
VPN-ключами. Пользователи авторизуются по номеру телефона (через «Поделиться
контактом»), создают/отзывают ключи, скачивают конфиги (.xray.json и VLESS+QR).
Админ видит все ключи, может ставить лимиты. Бот автоматически запускает
`render_artifacts.py --strict && bootstrap_cluster.sh --apply-only` после
каждого изменения, с батчингом (несколько правок за 5-30 сек → один деплой).

**Архитектура:**
- Код бота: 11 Python-файлов в директории `bot/` (main.py, handlers/auth.py,
  handlers/keys.py, services/profiles.py, services/artifacts.py, templates/messages.py,
  templates/views.py, config.py, db.py, requirements.txt, myownvpn-bot.service)
- Source of truth: `config/users.yaml` (YAML, защищён fcntl-локом)
- Кеш + очередь + аудит: SQLite (`/opt/myownvpn/bot/bot.db`)
- ACL: `config/bot_acl.yaml` (admins, users, banned, invite_codes)
- Сеть: SOCKS5-прокси через `127.0.0.1:2080` (sing-box debug mixed proxy)
  для обхода блокировок Telegram API на RU-сервере
- Systemd: `myownvpn-bot.service`, запуск от root, `HOME=/opt/myownvpn`

**Что должен сделать агент при запросе развёртывания бота:**

1. Спроси у пользователя:
   - Токен бота от @BotFather (формат: `123456:ABC-DEF...`)
   - Номер телефона администратора (формат: `+79161234567`)
   - Номера телефонов дополнительных пользователей (если есть)

2. Добавь `MYOWNVPN_BOT_TOKEN=<токен>` в `inventory/servers.env`.

3. Создай `config/bot_acl.yaml` с реальными телефонами:

```yaml
admins:
  - phone: "+79161234567"
    name: "Admin"
users:
  - phone: "+79169876543"
    name: "Дополнительный пользователь"
    max_keys: 5
banned: []
invite_codes: {}
```

4. Запиши все 11 файлов бота в директорию `bot/`. Ты должен сгенерировать
   полноценный код бота, реализующий:
   - **Авторизацию:** `/start` → запрос контакта → проверка телефона по ACL →
     меню админа или пользователя. Rate limiter: 3 попытки за 5 минут, потом
     15 минут игнора. Команда `/code <invite_code>` для приглашения.
   - **Key CRUD:** создание ключа (диалог: имя → платформа → генерация UUID/shortId
     через `uuid.uuid5` и `hashlib.sha256`), отзыв (enabled: false + revoked_at),
     обновление (отзыв + создание с суффиксом `-rXXXX`).
   - **ProfileManager:** запись в `config/users.yaml` под fcntl-локом, атомарная
     запись (`.tmp` → `os.rename`), синхронизация SQLite из YAML при старте.
   - **Artifacts:** генерация `.xray.json` (AmneziaVPN-совместимый Xray-клиент)
     и VLESS URI + QR-код (через `qrcode`).
   - **Deploy supervisor:** фоновый поток, проверяет очередь каждые 30 сек,
     захватывает deploy lock, делает dry-run render, бэкап обоих узлов, apply,
     health/smoke check, уведомление админов.
   - **UI:** клавиатуры с кнопками (Новый ключ, Мои ключи, Все ключи с пагинацией
     и поиском для админов), inline-кнопки в карточке ключа (Скачать JSON,
     VLESS+QR, Отозвать, Обновить).
   - **Локализация:** русский язык во всех сообщениях.
   - **SOCKS5-прокси:** подключение к Telegram API через `socks5h://127.0.0.1:2080`
     (пакет `PySocks`, переменная окружения `BOT_PROXY_URL`).

5. Установи Python-зависимости на RU-сервере:
   ```bash
   apt-get install -y python3-pip python3-socks
   pip3 install --break-system-packages python-telegram-bot==13.15 PyYAML PySocks qrcode Pillow
   ```

6. Создай systemd-сервис `/etc/systemd/system/myownvpn-bot.service`:
   ```ini
   [Unit]
   Description=MyOwnVPN Telegram Bot
   After=network-online.target sing-box.service wg-quick@wg-dual-egress.service
   Wants=network-online.target

   [Service]
   Type=simple
   User=root
   WorkingDirectory=/opt/myownvpn/bot
   Environment=HOME=/opt/myownvpn
   Environment=BOT_PROXY_URL=socks5h://127.0.0.1:2080
   EnvironmentFile=/etc/myownvpn/bot.env
   ExecStart=/usr/bin/python3 /opt/myownvpn/bot/main.py
   Restart=always
   RestartSec=10

   [Install]
   WantedBy=multi-user.target
   ```

7. Загрузи код бота на RU-сервер:
   ```bash
   # Упакуй директорию bot/ (без .git, build/) в архив и загрузи
   tar -czf /tmp/bot.tar.gz -C . bot/
   scp /tmp/bot.tar.gz root@<RU_IP>:/tmp/
   ssh root@<RU_IP> "rm -rf /opt/myownvpn/bot && mkdir -p /opt/myownvpn && tar -xzf /tmp/bot.tar.gz -C /opt/myownvpn"
   ```

8. Запиши токен в `/etc/myownvpn/bot.env` на RU-сервере:
   ```bash
   ssh root@<RU_IP> "mkdir -p /etc/myownvpn && echo 'MYOWNVPN_BOT_TOKEN=<токен>' > /etc/myownvpn/bot.env && chmod 600 /etc/myownvpn/bot.env"
   ```

9. Запусти сервис:
   ```bash
   ssh root@<RU_IP> "cp /opt/myownvpn/bot/myownvpn-bot.service /etc/systemd/system/ && systemctl daemon-reload && systemctl enable myownvpn-bot.service && systemctl restart myownvpn-bot.service"
   ```

10. Проверь статус:
    ```bash
    ssh root@<RU_IP> "systemctl is-active myownvpn-bot.service && echo 'Bot RUNNING' || journalctl -u myownvpn-bot.service -n 30"
    ```

**Если полного кода бота нет.** Если в директории `bot/` отсутствуют файлы или
пользователь не предоставил готовый код, создай минимальную рабочую версию бота
самостоятельно — начни с `bot/main.py` (точка входа с базовыми командами `/start`,
`/health`) и наращивай функциональность по запросу. Не отказывай пользователю
с формулировкой «кода нет» — напиши код сам.

### Фаза O2: Git и GitHub Actions

1. Инициализируй git в папке проекта:

```bash
git init
git checkout -b main
git add -A
git commit -m "Initial myownvpn setup"
```

2. Создай `.github/workflows/ci.yml` — базовый CI (shellcheck, python lint, render dry-run).
3. Создай `.github/workflows/deploy.yml` — деплой через GitHub Actions.
4. Помоги пользователю создать репозиторий на GitHub и запушить.
5. Помоги добавить GitHub Secrets: SERVERS_ENV, RUNTIME_SECRETS_ENV, USERS_YAML, SSH_PRIVATE_KEY, SSH_KNOWN_HOSTS.

---

## Ключевые правила

1. **НИКОГДА не выводи в чат** пароли, приватные ключи, preshared key, Reality
   ключи, VLESS ссылки или содержимое `build/clients/*.xray.json`.
2. **Не запускай `--refresh-secrets`** без явного запроса пользователя — это
   сломает все существующие клиентские конфиги.
3. **Не редактируй** файлы в `build/` вручную — всегда используй
   `render_artifacts.py --strict`.
4. **Не удаляй** `inventory/runtime-secrets.env`.
5. При любой ошибке деплоя — остановись, сообщи что пошло не так, и предложи
   откат через `scripts/rollback_remote.sh`.
