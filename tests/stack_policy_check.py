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
  - uses the shared default bridge (docker0) instead of a per-stack user-defined network —
    via `network_mode: bridge` or an external network resolving to `bridge`/`docker0`,
  - is missing `cap_drop: [ALL]`, or re-adds a dangerous capability via `cap_add`
    (with or without the `CAP_` prefix),
  - weakens the sandbox via `security_opt` (unconfined / label:disable / no-new-privileges:false),
  - bind-mounts the docker socket, a whole system directory (/, /etc, /usr, ...), or a
    sensitive host path (/proc, /sys, /dev, /var/run, ...),
  - passes through host `devices:`.

It also prints a non-fatal WARNING (still exit 0) for any service whose `image:` is not
digest-pinned — `:latest`, no tag, or a tag without an `@sha256:` digest. Pin a digest for
reproducible, immutable deploys.

Usage: stack_policy_check.py <compose.yml> [more.yml ...]
YAML input requires PyYAML (`pip install pyyaml`); resolved JSON uses the standard library.
"""
import json
import os
import posixpath
import re
import sys

try:
    import yaml
except ImportError:
    yaml = None  # Remote deployment supplies resolved JSON; no third-party parser needed.

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
    "/var/lib/containerd", "/var/lib/systemd", "/var/spool/cron",
    "/etc/ssh", "/etc/systemd", "/etc/sudoers.d", "/etc/pam.d",
    "/etc/cron.d", "/etc/cron.daily", "/etc/cron.hourly", "/etc/cron.weekly", "/etc/cron.monthly",
    "/etc/apt", "/etc/traefik", "/etc/alloy", "/etc/miuops-backup",
    "/opt/cloudflared", "/opt/stacks", "/home",
)
# Exact matches — mounting the WHOLE directory is dangerous, but a specific file under it
# (e.g. /etc/localtime, /usr/share/...) is fine:
SENSITIVE_MOUNT_EXACT = frozenset({
    "/", "/etc", "/var", "/var/lib", "/home", "/usr", "/bin", "/sbin", "/lib", "/opt",
})
# Specific sensitive files, wherever they would be mounted:
SENSITIVE_MOUNT_FILES = frozenset({"/etc/shadow", "/etc/gshadow", "/etc/passwd", "/etc/sudoers", "/etc/crontab"})


def _is_truthy(value):
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"true", "yes", "on", "1"}


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


def _file_entries(value):
    """Normalise a compose field that may be a string, a mapping, or a list of either."""
    if value is None:
        return []
    if isinstance(value, (list, tuple)):
        return list(value)
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


def _volume_bind_source(vol):
    """Return the host source path if a service volume entry is a bind mount, else None."""
    if isinstance(vol, dict):
        vol_type = str(vol.get("type") or "").strip().lower()
        source = vol.get("source")
        if vol_type == "bind":
            return str(source) if source else "<missing-bind-source>"
        if not source or vol_type != "":
            return None  # type: volume / tmpfs / npipe / cluster / image
        text = str(source)
        return text if (text.startswith(("/", "~", ".")) or "/" in text or "$" in text) else None
    spec = str(vol)
    if "$" in spec:
        return spec
    if ":" not in spec:
        return None  # anonymous container-only volume
    source = spec.split(":", 1)[0]
    if not source:
        return None
    return source if (source.startswith(("/", "~", ".")) or "/" in source) else None


COMPOSE_FILENAMES = (
    "compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml",
    "compose.override.yaml", "compose.override.yml",
    "docker-compose.override.yaml", "docker-compose.override.yml",
)


def _is_valid_stack_base_dir(real_base):
    """True if `real_base` can legitimately be a stack directory containing stack-local files.

    Stacks live in `/opt/stacks/<stack>` on servers or under `/home/<user>/...` (Linux),
    `/Users/...` (macOS), or temp directories in CI/tests — never directly at `/opt/stacks`
    or `/home`, and never inside host system directories (`/etc`, `/proc`, `/var/run`, ...).
    """
    path = real_base
    if sys.platform == "darwin" and path.startswith(("/private/etc", "/private/var")):
        path = path[len("/private"):]
    if path.startswith("/opt/stacks/") and path != "/opt/stacks/":
        return True
    if path.startswith("/home/") and "/" in path[len("/home/"):].strip("/"):
        return True
    return not _is_sensitive_mount(path)


def _is_volume_read_only(vol):
    """True if a service volume entry explicitly mounts read-only (`:ro` or `read_only: true`)."""
    if isinstance(vol, dict):
        return _is_truthy(vol.get("read_only"))
    parts = str(vol).split(":")
    if len(parts) != 3:
        return False
    modes = {m.strip().lower() for m in parts[2].split(",") if m.strip()}
    return "ro" in modes and "rw" not in modes


def _resolve_stack_local(source, base_dir):
    """Return (candidate, resolved, abs_base, real_base) if `source` stays strictly inside valid `base_dir`."""
    if not base_dir:
        return None
    text = str(source)
    if "docker.sock" in text or text.startswith("~") or "$" in text:
        return None
    is_rel = not os.path.isabs(text)
    candidate = os.path.join(os.path.abspath(base_dir), text) if is_rel else text
    if not os.path.isabs(candidate):
        return None
    resolved = os.path.realpath(candidate)
    if "docker.sock" in resolved:
        return None
    abs_base = posixpath.normpath(os.path.abspath(base_dir))
    real_base = os.path.realpath(base_dir)
    norm_cand = posixpath.normpath(candidate)
    if (
        _is_valid_stack_base_dir(real_base)
        and (norm_cand.startswith(abs_base + "/") or norm_cand.startswith(real_base + "/"))
        and resolved.startswith(real_base + "/")
    ):
        return norm_cand, resolved, abs_base, real_base
    return None


def _is_stack_local_mount(source, base_dir=None):
    """True if `source` resolves strictly inside a valid stack `base_dir`."""
    return _resolve_stack_local(source, base_dir) is not None


def _is_forbidden_name(name, allow_env_ext=False):
    low = name.lower()
    lower_compose = {c.lower() for c in COMPOSE_FILENAMES}
    if low in lower_compose or low in {".env", ".git"} or low.startswith(".miuops-config"):
        return True
    if not allow_env_ext and (low.endswith(".env") or low.startswith(".env.")):
        return True
    return False


def _is_forbidden_stack_local_file(candidate, resolved, abs_base, real_base, allow_env_ext=False):
    """True if a stack-local path targets compose definitions, .env files, .git, or temp configs,
    or is a directory containing any forbidden file or symlink escaping `real_base`.
    """
    cand_root = real_base if candidate.startswith(real_base + "/") else abs_base
    for p, root in ((candidate, cand_root), (resolved, real_base)):
        if _is_forbidden_name(os.path.basename(p), allow_env_ext=allow_env_ext):
            return True
        try:
            rel_parts = posixpath.relpath(p, root).split("/")
        except ValueError:
            return True
        if any(_is_forbidden_name(part, allow_env_ext=allow_env_ext) for part in rel_parts):
            return True
    if os.path.isdir(resolved):
        for walk_root, dirnames, filenames in os.walk(resolved, followlinks=False):
            for entry in list(dirnames) + list(filenames):
                if _is_forbidden_name(entry, allow_env_ext=allow_env_ext):
                    return True
                full_entry = os.path.join(walk_root, entry)
                real_entry = os.path.realpath(full_entry)
                if "docker.sock" in real_entry or not real_entry.startswith(real_base + "/"):
                    return True
    return False


def _is_sensitive_resolved_mount(source, base_dir=None, allow_env_ext=False):
    # Deployment runs this on the destination host, after Compose has expanded
    # relative bind sources. Docker follows symlinks that Compose leaves intact.
    text = str(source)
    if "docker.sock" in text or text.startswith("~") or "$" in text:
        return True
    local = _resolve_stack_local(text, base_dir)
    if local is not None:
        candidate, resolved, abs_base, real_base = local
        return _is_forbidden_stack_local_file(
            candidate, resolved, abs_base, real_base, allow_env_ext=allow_env_ext
        )
    is_rel = not os.path.isabs(text)
    if base_dir and is_rel:
        return True  # relative path escaped stack dir (via .. or symlink) or mounted '.'
    candidate = os.path.join(os.path.abspath(base_dir), text) if (base_dir and is_rel) else text
    if os.path.isabs(candidate):
        resolved = os.path.realpath(candidate)
        if _is_sensitive_mount(candidate) or _is_sensitive_mount(resolved):
            return True
        if sys.platform == "darwin" and resolved.startswith(("/private/etc", "/private/var")):
            return _is_sensitive_mount(resolved[len("/private"):])
    return _is_sensitive_mount(text)


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


def _image_pin_warning(image):
    """Return an advisory string if an image reference is not digest-pinned, else None.

    A digest-pinned image (`name@sha256:...`) is immutable and reproducible. A bare
    `:latest`, no tag, or a mutable version tag can change between deploys.
    """
    ref = str(image).strip()
    if "@sha256:" in ref:
        return None  # digest-pinned — immutable
    _repo, sep, tag = ref.rpartition(":")
    has_tag = bool(sep) and "/" not in tag  # a trailing `:port/path` is a registry port, not a tag
    if not has_tag:
        return f"image '{ref}' is untagged — pin a digest (image@sha256:...) for an immutable deploy"
    if tag == "latest":
        return f"image '{ref}' uses the mutable ':latest' tag — pin a digest (image@sha256:...)"
    return f"image '{ref}' is not digest-pinned — consider a digest (image@sha256:...) for immutability"


def check_file(path):
    """Return (violations, warnings) for one compose file — both lists of strings.

    Violations cause a non-zero exit; warnings are advisory (e.g. an un-pinned image).
    """
    try:
        with open(path) as handle:
            content = handle.read()
        try:
            doc = json.loads(content)
        except ValueError:
            if yaml is None:
                raise ValueError("Expected resolved Compose JSON (PyYAML needed for YAML input)")
            try:
                doc = yaml.safe_load(content)
            except yaml.YAMLError as exc:
                raise ValueError(str(exc)) from exc
    except (OSError, ValueError) as exc:
        return [f"{path}: cannot read/parse compose file: {exc}"], []
    if not isinstance(doc, dict):
        return [f"{path}: not a valid compose mapping"], []

    if doc.get("include") is not None:
        return [f"{path}: uses top-level 'include' (declare all services directly in the stack compose file)"], []

    services = doc.get("services")
    if services is None:
        return [], []  # no services → nothing to publish or privilege
    if not isinstance(services, dict):
        return [f"{path}: `services` is not a mapping"], []

    base_dir = os.path.dirname(os.path.abspath(path))
    violations = []
    warnings = []
    for name, svc in services.items():
        prefix = f"{path}: service '{name}'"
        if not isinstance(svc, dict):
            violations.append(f"{prefix} is not a mapping")
            continue

        if svc.get("extends") is not None:
            violations.append(f"{prefix} uses 'extends' (declare service configuration directly)")

        image = svc.get("image")
        if image is not None:
            warn = _image_pin_warning(image)
            if warn:
                warnings.append(f"{prefix} {warn}")

        if _is_truthy(svc.get("privileged")):
            violations.append(f"{prefix} sets privileged")

        network_mode = str(svc.get("network_mode", "")).strip()
        if network_mode == "host" and svc.get("x-miuops-allow-host-net") is not True:
            violations.append(f"{prefix} uses network_mode: host "
                              "(add `x-miuops-allow-host-net: true` to opt in if intentional)")
        elif network_mode.startswith(("container:", "service:")):
            violations.append(f"{prefix} uses network_mode: {network_mode} (joins another container's net ns)")
        elif network_mode == "bridge":
            violations.append(f"{prefix} uses network_mode: bridge (the shared default bridge / docker0); "
                              "put the service on a per-stack user-defined network instead")
        for field in ("pid", "ipc", "uts", "cgroup"):
            value = str(svc.get(field, "")).strip()
            if value == "host" or value.startswith(("container:", "service:")):
                violations.append(f"{prefix} uses {field}: {value}")
        if str(svc.get("cgroupns")).strip() == "host":
            violations.append(f"{prefix} uses cgroupns: host")
        if str(svc.get("userns_mode")).strip() == "host":
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

        if _as_list(svc.get("volumes_from")):
            violations.append(f"{prefix} uses volumes_from (mounts another container's volumes)")

        for vol in _as_list(svc.get("volumes")):
            source = _volume_bind_source(vol)
            if not source:
                continue
            if _is_sensitive_resolved_mount(source, base_dir=base_dir):
                violations.append(f"{prefix} bind-mounts a sensitive host path: {source!r}")
            elif _is_stack_local_mount(source, base_dir=base_dir) and not _is_volume_read_only(vol):
                violations.append(
                    f"{prefix} bind-mounts stack-local path {source!r} without read-only (:ro / read_only: true); "
                    "use a named volume for writable data"
                )

        for field in ("env_file", "label_file"):
            for entry in _file_entries(svc.get(field)):
                entry_path = entry.get("path") if isinstance(entry, dict) else entry
                if entry_path is not None and not isinstance(entry_path, str):
                    violations.append(f"{prefix} has non-string path in {field}")
                elif entry_path and "$" in str(entry_path):
                    violations.append(f"{prefix} uses variable interpolation in {field}: {entry_path!r}")
                elif entry_path and _is_sensitive_resolved_mount(
                    entry_path, base_dir=base_dir, allow_env_ext=(field == "env_file")
                ):
                    violations.append(f"{prefix} references a sensitive host path in {field}: {entry_path!r}")

        if _as_list(svc.get("devices")):
            violations.append(f"{prefix} passes through host devices (raw device access)")

        for port in _as_list(svc.get("ports")):
            host_ip = _published_host_ip(port)
            if host_ip is None:
                violations.append(f"{prefix} publishes {port!r} without binding a host IP "
                                  "(use `127.0.0.1:<host>:<container>`)")
            elif host_ip not in LOOPBACK_HOST_IPS:
                violations.append(f"{prefix} publishes {port!r} to {host_ip} (must bind 127.0.0.1)")

    # Local named volumes can hide a host bind behind driver_opts instead of a
    # service-level source. Apply the same destination-host path checks there.
    volumes = doc.get("volumes")
    if isinstance(volumes, dict):
        for volume_name, volume in volumes.items():
            if not isinstance(volume, dict) or volume.get("driver", "local") != "local":
                continue
            options = volume.get("driver_opts") or {}
            flags = {flag.strip() for flag in str(options.get("o", "")).split(",")}
            if options.get("type") == "none" or flags & {"bind", "rbind"}:
                device = options.get("device")
                if not isinstance(device, str) or not os.path.isabs(device):
                    violations.append(f"{path}: volume '{volume_name}' bind device must be an absolute host path")
                elif _is_sensitive_resolved_mount(device, base_dir=base_dir) or _is_stack_local_mount(device, base_dir=base_dir):
                    violations.append(f"{path}: volume '{volume_name}' bind-mounts a sensitive host path: {device!r}")

    # Top-level secrets/configs with `file:` bind-mount host files into containers.
    for section in ("secrets", "configs"):
        items = doc.get(section)
        if isinstance(items, dict):
            for item_name, item in items.items():
                if isinstance(item, dict):
                    file_path = item.get("file")
                    if file_path is not None and not isinstance(file_path, str):
                        violations.append(f"{path}: {section[:-1]} '{item_name}' has non-string file path")
                    elif file_path and "$" in str(file_path):
                        violations.append(
                            f"{path}: {section[:-1]} '{item_name}' uses variable interpolation in file: {file_path!r}"
                        )
                    elif file_path and _is_sensitive_resolved_mount(file_path, base_dir=base_dir):
                        violations.append(
                            f"{path}: {section[:-1]} '{item_name}' reads a sensitive host path: {file_path!r}"
                        )

    # File-level: reject attaching to the shared default bridge (docker0) through an external
    # network — the back door that evades the per-service `network_mode: bridge` check above.
    networks = doc.get("networks")
    if isinstance(networks, dict):
        for net_name, net in networks.items():
            if not isinstance(net, dict):
                continue
            ext = net.get("external")
            # `external: true` (current) or `external: {name: ...}` (legacy) both mark it external.
            # NB: a dict is NOT _is_truthy (that is a str/bool coercion), so check isinstance too.
            if not (_is_truthy(ext) or isinstance(ext, dict)):
                continue
            backing = net.get("name")
            if backing is None and isinstance(ext, dict):
                backing = ext.get("name")  # legacy `external: {name: ...}` form
            if str(backing if backing is not None else net_name).lower() in ("bridge", "docker0"):
                violations.append(f"{path}: network '{net_name}' attaches to the shared default "
                                  "bridge (docker0); use a per-stack network")

    return violations, warnings


def _strip_yaml_quotes(value):
    text = value.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in ("'", '"'):
        return text[1:-1]
    return text


_KEY_RE = re.compile(r"""^['"]?(env_file|label_file|file|include|extends)['"]?\s*:(.*)$""")


def _scan_pre_config_text(content, path, base_dir):
    """Fail-closed stdlib scanner when PyYAML is absent on the destination host."""
    violations = []
    block_field = None
    block_indent = -1
    for raw_line in content.splitlines():
        if re.match(r"^\s*%", raw_line):
            violations.append(f"{path}: YAML directives are not allowed in pre-config policy check")
            continue
        stripped = raw_line.split("#", 1)[0].rstrip()
        if not stripped.strip():
            continue
        indent = len(raw_line) - len(raw_line.lstrip(" "))
        text = stripped.strip()
        if any(k in text for k in ("include:", "extends:", '"include"', "'include'", '"extends"', "'extends'")):
            m_inline = re.search(r"""['"]?(include|extends)['"]?\s*:""", text)
            if m_inline:
                violations.append(f"{path}: uses '{m_inline.group(1)}' (not permitted by stack policy)")
                continue
        if block_field is not None and indent <= block_indent and not text.startswith("-"):
            block_field = None
        if block_field is not None:
            if "$" in text:
                violations.append(f"{path}: uses variable interpolation in {block_field}: {text!r}")
                continue
            if any(ch in text for ch in ("{", "}", "[", "]", "|", ">")):
                violations.append(f"{path}: complex YAML syntax in {block_field} requires PyYAML")
                continue
            candidate = text[1:].strip() if text.startswith("-") else text
            m_kv = re.match(r"""^['"]?([A-Za-z0-9_.-]+)['"]?\s*:\s*(.*)$""", candidate)
            if m_kv:
                if m_kv.group(1) in ("required", "format"):
                    continue
                candidate = m_kv.group(2).strip() if m_kv.group(1) == "path" else candidate
            candidate = _strip_yaml_quotes(candidate)
            if "$" in candidate:
                violations.append(f"{path}: uses variable interpolation in {block_field}: {candidate!r}")
            elif candidate and _is_sensitive_resolved_mount(
                candidate, base_dir=base_dir, allow_env_ext=(block_field == "env_file")
            ):
                violations.append(f"{path}: references a sensitive host path in {block_field}: {candidate!r}")
            continue
        m = _KEY_RE.match(text)
        if m:
            key, val = m.group(1), m.group(2).strip()
            if key in ("include", "extends"):
                violations.append(f"{path}: uses '{key}' (not permitted by stack policy)")
                continue
            if not val:
                block_field = key
                block_indent = indent
            elif "$" in val:
                violations.append(f"{path}: uses variable interpolation in {key}: {val!r}")
            elif val in ("|", ">", "|-", ">-", "|+", ">+") or "{" in val or "}" in val:
                violations.append(f"{path}: complex YAML syntax in {key} requires PyYAML")
            elif val.startswith("["):
                if not val.endswith("]"):
                    violations.append(f"{path}: multi-line flow sequence in {key} is not permitted")
                else:
                    for elem in val[1:-1].split(","):
                        c = _strip_yaml_quotes(elem)
                        if "$" in c:
                            violations.append(f"{path}: uses variable interpolation in {key}: {c!r}")
                        elif c and _is_sensitive_resolved_mount(
                            c, base_dir=base_dir, allow_env_ext=(key == "env_file")
                        ):
                            violations.append(f"{path}: references a sensitive host path in {key}: {c!r}")
            else:
                c = _strip_yaml_quotes(val)
                if "$" in c:
                    violations.append(f"{path}: uses variable interpolation in {key}: {c!r}")
                elif c and _is_sensitive_resolved_mount(
                    c, base_dir=base_dir, allow_env_ext=(key == "env_file")
                ):
                    violations.append(f"{path}: references a sensitive host path in {key}: {c!r}")
    return violations


def check_pre_config_dir(stack_dir):
    """Check raw compose files in stack_dir for sensitive env_file/label_file/secrets/configs
    before `docker compose config --format json` reads and inlines env_file contents from the host disk.
    Fails closed on unreadable or unparseable compose files.
    """
    violations = []
    base_dir = os.path.abspath(stack_dir)
    for cf in COMPOSE_FILENAMES:
        path = os.path.join(base_dir, cf)
        if os.path.islink(path):
            violations.append(f"{path}: compose file is a symbolic link")
            continue
        if not os.path.isfile(path):
            continue
        try:
            with open(path) as handle:
                content = handle.read()
        except OSError as exc:
            violations.append(f"{path}: cannot read compose file: {exc}")
            continue
        try:
            doc = json.loads(content)
        except ValueError:
            if yaml is None:
                violations.extend(_scan_pre_config_text(content, path, base_dir))
                continue
            try:
                doc = yaml.safe_load(content)
            except Exception as exc:
                violations.append(f"{path}: cannot parse compose YAML in pre-config policy check: {exc}")
                continue
        if not isinstance(doc, dict):
            violations.append(f"{path}: not a valid compose mapping")
            continue
        if doc.get("include") is not None:
            violations.append(f"{path}: uses top-level 'include' (declare all services directly)")
        services = doc.get("services")
        if isinstance(services, dict):
            for name, svc in services.items():
                if not isinstance(svc, dict):
                    violations.append(f"{path} [service '{name}'] is not a mapping")
                    continue
                prefix = f"{path} [service '{name}']"
                if svc.get("extends") is not None:
                    violations.append(f"{prefix} uses 'extends' (declare service configuration directly)")
                for field in ("env_file", "label_file"):
                    for entry in _file_entries(svc.get(field)):
                        entry_path = entry.get("path") if isinstance(entry, dict) else entry
                        if entry_path is not None and not isinstance(entry_path, str):
                            violations.append(f"{prefix} has non-string path in {field}")
                        elif entry_path and "$" in str(entry_path):
                            violations.append(f"{prefix} uses variable interpolation in {field}: {entry_path!r}")
                        elif entry_path and _is_sensitive_resolved_mount(
                            entry_path, base_dir=base_dir, allow_env_ext=(field == "env_file")
                        ):
                            violations.append(
                                f"{prefix} references a sensitive host path in {field}: {entry_path!r}"
                            )
        for section in ("secrets", "configs"):
            items = doc.get(section)
            if isinstance(items, dict):
                for item_name, item in items.items():
                    if isinstance(item, dict):
                        file_path = item.get("file")
                        if file_path is not None and not isinstance(file_path, str):
                            violations.append(f"{path}: {section[:-1]} '{item_name}' has non-string file path")
                        elif file_path and "$" in str(file_path):
                            violations.append(
                                f"{path}: {section[:-1]} '{item_name}' uses variable interpolation in file: {file_path!r}"
                            )
                        elif file_path and _is_sensitive_resolved_mount(file_path, base_dir=base_dir):
                            violations.append(
                                f"{path}: {section[:-1]} '{item_name}' reads a sensitive host path: {file_path!r}"
                            )
    return violations


def main(argv):
    if not argv:
        sys.stderr.write(__doc__)
        return 2
    if len(argv) == 2 and argv[0] == "--pre-config":
        violations = check_pre_config_dir(argv[1])
        if violations:
            sys.stderr.write("Stack policy-check FAILED:\n")
            for item in violations:
                sys.stderr.write(f"  - {item}\n")
            return 1
        return 0
    all_violations = []
    all_warnings = []
    for path in argv:
        violations, warnings = check_file(path)
        all_violations.extend(violations)
        all_warnings.extend(warnings)
    if all_warnings:
        sys.stderr.write("Stack policy-check warnings (advisory, non-blocking):\n")
        for item in all_warnings:
            sys.stderr.write(f"  ! {item}\n")
    if all_violations:
        sys.stderr.write("Stack policy-check FAILED:\n")
        for item in all_violations:
            sys.stderr.write(f"  - {item}\n")
        return 1
    print(f"Stack policy-check passed ({len(argv)} file(s)).")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
