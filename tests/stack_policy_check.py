#!/usr/bin/env python3
"""Stack policy-check — reject compose files that would expose or over-privilege containers.

miuops keeps published container ports off the public interface and minimises container
privilege at *publish time* (this gate), not with a runtime firewall. A compose file FAILS
(exit 1) if any service:

  - publishes a port to anything other than the loopback host IP (`127.0.0.1:` / `[::1]:`);
    a short mapping like `8080:80` or `0.0.0.0:8080:80` is rejected,
  - sets `privileged` (true / "true" / 1),
  - shares a host namespace — `network_mode`/`pid`/`ipc`/`uts`/`cgroup: host`,
    `cgroupns: host`, `userns_mode: host`, or `network_mode/pid/ipc: "container:..."`
    (host networking can be opted in per service with `x-miuops-allow-host-net: true`),
  - is missing `cap_drop: [ALL]`, or re-adds a dangerous capability via `cap_add`
    (with or without the `CAP_` prefix),
  - weakens the sandbox via `security_opt` (unconfined / label:disable / no-new-privileges:false),
  - bind-mounts the docker socket (allowed ONLY for a read-only docker-socket-proxy that
    opts in with `x-miuops-docker-socket-proxy: true`, `POST=0`, and a `:ro` mount), a
    whole system directory (/, /etc, /usr, ...), or a sensitive host path (/proc, /sys, ...),
  - passes through host `devices:`.

Usage: stack_policy_check.py <compose.yml> [more.yml ...]
Requires PyYAML (`pip install pyyaml`).
"""
import posixpath
import re
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("stack_policy_check: PyYAML is required (pip install pyyaml)\n")
    sys.exit(2)

LOOPBACK_HOST_IPS = {"127.0.0.1", "::1"}

# Capabilities that grant (near-)host-level power; never allowed back via cap_add.
DANGEROUS_CAPS = {
    "ALL", "SYS_ADMIN", "SYS_MODULE", "SYS_RAWIO", "SYS_PTRACE", "SYS_BOOT", "SYS_TIME",
    "SYS_CHROOT", "NET_ADMIN", "DAC_READ_SEARCH", "DAC_OVERRIDE", "MAC_ADMIN",
    "MAC_OVERRIDE", "LINUX_IMMUTABLE", "BPF", "PERFMON", "SYSLOG", "WAKE_ALARM",
    "MKNOD", "AUDIT_CONTROL", "SETPCAP", "SETFCAP",
}

# Host paths whose bind-mount hands a container effective control of the host.
# Prefix matches — the directory and everything under it (no legitimate container use):
SENSITIVE_MOUNT_PREFIXES = (
    "/proc", "/sys", "/dev", "/boot", "/root", "/var/run", "/run", "/var/lib/docker",
)
# Exact matches — mounting the WHOLE directory is dangerous, but a specific file under it
# (e.g. /etc/localtime, /usr/share/...) is fine:
SENSITIVE_MOUNT_EXACT = frozenset({
    "/", "/etc", "/var", "/var/lib", "/home", "/usr", "/bin", "/sbin", "/lib", "/opt",
})
# Specific sensitive files, wherever they would be mounted:
SENSITIVE_MOUNT_FILES = frozenset({"/etc/shadow", "/etc/gshadow", "/etc/passwd", "/etc/sudoers"})


def _is_truthy(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0  # POST: 1.0 / 2 are truthy; the proxy reads them as "on"
    text = str(value).strip().lower()
    if text in {"true", "yes", "on"}:
        return True
    # Mirror the proxy's HAProxy `-m bool` parse (read_int64): an optional sign + leading
    # decimal digits, nonzero => enabled. So "1", "01", "2.9", "-1", "1abc" are all truthy,
    # matching the running proxy — a writable value can't read as "read-only" here.
    leading_int = re.match(r"[+-]?\d+", text)
    return bool(leading_int) and int(leading_int.group()) != 0


def _norm_cap(cap):
    """Upper-case a capability name and strip the optional CAP_ prefix.

    `CAP_SYS_ADMIN` and `SYS_ADMIN` are equivalent to the runtime, so both must match.
    """
    name = str(cap).strip().upper()
    return name[4:] if name.startswith("CAP_") else name


def _as_list(value):
    """Normalise a compose field that may be a list, a mapping, a scalar, or None.

    A mapping yields its KEYS — fine for fields whose tokens are keys (ports, volumes,
    cap_*), not for fields whose value carries the signal.
    """
    if value is None:
        return []
    if isinstance(value, (list, tuple)):
        return list(value)
    if isinstance(value, dict):
        return list(value.keys())
    return [value]


def _is_sensitive_mount(source):
    text = str(source)
    if "docker.sock" in text:
        return True
    if not text.startswith(("/", "~", "./", "../")):
        return False  # a named volume, not a host bind mount
    path = posixpath.normpath(text)  # collapse /./, /../, // obfuscation lexically
    if path.startswith("//"):  # POSIX keeps exactly two leading slashes; normalise
        path = path[1:]
    if path in SENSITIVE_MOUNT_EXACT or path in SENSITIVE_MOUNT_FILES:
        return True
    return any(path == pre or path.startswith(pre + "/") for pre in SENSITIVE_MOUNT_PREFIXES)


def _published_host_ip(port):
    """Host IP a port mapping binds to, or None if none is set explicitly.

    Accepts short syntax ("127.0.0.1:8080:80", "[::1]:8080:80", "8080:80", "80/udp") and
    long syntax (a mapping with an optional `host_ip`).
    """
    if isinstance(port, dict):
        return port.get("host_ip")
    text = str(port).split("/", 1)[0]  # drop any /tcp /udp suffix
    if text.startswith("["):  # [ipv6]:host:container | [ipv6]:host | [ipv6]
        host_ip, sep, _rest = text[1:].partition("]")
        return host_ip if sep else None
    parts = text.split(":")
    if len(parts) == 3:  # host_ip:host_port:container_port
        return parts[0]
    return None  # "host:container" or "container" — no explicit host IP


def _env_map(environment):
    """compose `environment` as a dict; accepts a mapping or a ['KEY=value', ...] list.

    A bare `KEY` (host-env pass-through) maps to "" — its real value is unknown here, so
    the read-only checks treat it as not-enabled. This is a publish-time guardrail, not a
    defence against a deliberately obfuscated compose.
    """
    if isinstance(environment, dict):
        return {str(k): ("" if v is None else v) for k, v in environment.items()}
    result = {}
    for item in _as_list(environment):
        key, sep, value = str(item).partition("=")
        result[key.strip()] = value.strip() if sep else ""
    return result


def _mount_is_read_only(vol):
    """True if a compose volume mount is read-only (`:ro` short syntax / `read_only: true`)."""
    if isinstance(vol, dict):
        return bool(vol.get("read_only"))
    parts = str(vol).split(":")
    return len(parts) >= 3 and "ro" in parts[2].split(",")


def _is_approved_socket_proxy(svc):
    """True iff this service is an explicitly-opted-in, read-only docker-socket-proxy.

    The docker socket is root-equivalent, so it is the one host path a service may bind —
    and only when (a) the service is marked `x-miuops-docker-socket-proxy: true`, (b) it
    publishes no host port (it is reached only over the internal Docker network, never
    re-exposed), and (c) it is configured read-only: `POST` is off (GET/HEAD only) and no
    secret- or exec-exposing section (SECRETS / CONFIGS / AUTH / EXEC) is enabled. Combined
    with the read-only mount flag checked at the call site, a compromised proxy can only
    LIST/READ the Docker API — never start/exec/modify or read swarm secrets.
    """
    if svc.get("x-miuops-docker-socket-proxy") is not True:
        return False
    if _as_list(svc.get("ports")):
        return False  # reached over the internal network only — it must never publish a port
    env = _env_map(svc.get("environment"))
    if _is_truthy(env.get("POST")):
        return False
    return not any(_is_truthy(env.get(section)) for section in ("SECRETS", "CONFIGS", "AUTH", "EXEC"))


def check_file(path):
    """Return a list of policy-violation strings for one compose file (empty = clean)."""
    try:
        with open(path) as handle:
            doc = yaml.safe_load(handle)
    except (OSError, yaml.YAMLError) as exc:
        return [f"{path}: cannot read/parse compose file: {exc}"]
    if not isinstance(doc, dict):
        return [f"{path}: not a valid compose mapping"]

    services = doc.get("services")
    if services is None:
        return []  # no services → nothing to publish or privilege
    if not isinstance(services, dict):
        return [f"{path}: `services` is not a mapping"]

    violations = []
    for name, svc in services.items():
        prefix = f"{path}: service '{name}'"
        if not isinstance(svc, dict):
            violations.append(f"{prefix} is not a mapping")
            continue

        if _is_truthy(svc.get("privileged")):
            violations.append(f"{prefix} sets privileged")

        network_mode = str(svc.get("network_mode", ""))
        if network_mode == "host" and svc.get("x-miuops-allow-host-net") is not True:
            violations.append(f"{prefix} uses network_mode: host "
                              "(add `x-miuops-allow-host-net: true` to opt in if intentional)")
        elif network_mode.startswith("container:"):
            violations.append(f"{prefix} uses network_mode: container (joins another container's net ns)")
        for field in ("pid", "ipc", "uts", "cgroup"):
            value = str(svc.get(field, ""))
            if value == "host" or value.startswith("container:"):
                violations.append(f"{prefix} uses {field}: {value}")
        if str(svc.get("cgroupns")) == "host":
            violations.append(f"{prefix} uses cgroupns: host")
        if str(svc.get("userns_mode")) == "host":
            violations.append(f"{prefix} uses userns_mode: host (defeats userns-remap)")

        cap_drop = {_norm_cap(c) for c in _as_list(svc.get("cap_drop"))}
        if "ALL" not in cap_drop:
            violations.append(f"{prefix} is missing cap_drop: [ALL]")
        bad_caps = {_norm_cap(c) for c in _as_list(svc.get("cap_add"))} & DANGEROUS_CAPS
        if bad_caps:
            violations.append(f"{prefix} re-adds dangerous capabilities via cap_add: {sorted(bad_caps)}")

        for opt in _as_list(svc.get("security_opt")):
            normalised = str(opt).lower().replace(" ", "").replace("=", ":")
            if "unconfined" in normalised or normalised in {"label:disable", "no-new-privileges:false"}:
                violations.append(f"{prefix} weakens the sandbox via security_opt: {opt!r}")

        proxy_ok = _is_approved_socket_proxy(svc)
        for vol in _as_list(svc.get("volumes")):
            source = vol.get("source") if isinstance(vol, dict) else str(vol).split(":", 1)[0]
            if not source or not _is_sensitive_mount(source):
                continue
            # The docker socket on an approved, read-only docker-socket-proxy is the one
            # permitted sensitive mount — Traefik et al. reach Docker through it, not raw.
            if "docker.sock" in str(source) and proxy_ok and _mount_is_read_only(vol):
                continue
            violations.append(f"{prefix} bind-mounts a sensitive host path: {source!r}")

        if _as_list(svc.get("devices")):
            violations.append(f"{prefix} passes through host devices (raw device access)")

        for port in _as_list(svc.get("ports")):
            host_ip = _published_host_ip(port)
            if host_ip is None:
                violations.append(f"{prefix} publishes {port!r} without binding a host IP "
                                  "(use `127.0.0.1:<host>:<container>`)")
            elif host_ip not in LOOPBACK_HOST_IPS:
                violations.append(f"{prefix} publishes {port!r} to {host_ip} (must bind 127.0.0.1)")

    return violations


def main(argv):
    if not argv:
        sys.stderr.write(__doc__)
        return 2
    all_violations = []
    for path in argv:
        all_violations.extend(check_file(path))
    if all_violations:
        sys.stderr.write("Stack policy-check FAILED:\n")
        for item in all_violations:
            sys.stderr.write(f"  - {item}\n")
        return 1
    print(f"Stack policy-check passed ({len(argv)} file(s)).")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
