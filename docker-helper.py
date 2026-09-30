#!/usr/bin/env python3
"""Bounded Docker access for the panel.

Every Docker command runs in its own process group under a strict overall
deadline, and stdout/stderr are read with per-stream byte limits. Exceeding a
limit kills the command, so a stuck daemon or a container with oversized
metadata or log lines cannot grow the shell's memory. Output is small and
self-describing:

  snapshot                  sectioned text for Model.parseSnapshot
  logs <id>                 JSON {"code", "text"} with the newest log lines
  grouplogs <id>...         JSON {"code", "text", "lines"}: several containers'
                            logs merged by timestamp, each line tagged with the
                            index of its container argument
  action <verb> <id>...     JSON {"code", "text"}; verb is start/stop/restart
  memory <name> <mb>        JSON {"code", "text"} for docker update --memory
  projects <dir>...         JSON {"code", "text", "projects"}: Compose projects
                            found under the folders plus those Docker knows
  up <compose-file>...      JSON {"code", "text"} for docker compose up -d
"""
import json
import os
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import re
import selectors
import signal
import subprocess
import sys
import time

KIB = 1024
MIB = 1024 * KIB

SNAPSHOT_DEADLINE = 12.0
LOGS_DEADLINE = 10.0
ACTION_DEADLINE = 45.0
PROJECTS_DEADLINE = 8.0
UP_DEADLINE = 600.0         # first start may pull or build images

COMPOSE_FILES = ("compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml")
SCAN_DEPTH = 4
SCAN_MAX_DIRS = 20000
SCAN_MAX_PROJECTS = 100
COMPOSE_READ_LIMIT = 256 * KIB
SKIP_DIRS = {"node_modules", "vendor", "venv", "target", "dist", "build", "__pycache__"}

INSPECT_LIMIT = 4 * MIB     # all container metadata together
STATS_LIMIT = 256 * KIB
SMALL_LIMIT = 64 * KIB      # version, ps -q, action output, stderr
LOG_READ_LIMIT = 8 * MIB    # bytes read per log stream before stopping
LOG_KEEP = 60000            # newest characters shown
LOG_LINES = 200
LOG_LINE_CHARS = 2000
GROUP_LOG_CONTAINERS = 32
GROUP_LOG_LINES = 400       # newest merged lines returned for a group
GROUP_LOG_READ_LIMIT = 2 * MIB  # bytes read per stream per container

ID_RE = re.compile(r"^[a-f0-9]{12,64}$")
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$")
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")

INSPECT_FORMAT = (
    '{"id":{{json .Id}},"name":{{json .Name}},"image":{{json .Config.Image}},'
    '"status":{{json .State.Status}},"memLimitBytes":{{.HostConfig.Memory}},'
    '"labels":{{json .Config.Labels}},'
    '"health":{{if .State.Health}}{{json .State.Health.Status}}{{else}}""{{end}},'
    '"restarts":{{.RestartCount}},"ports":{{json .NetworkSettings.Ports}},'
    '"networks":{{json .NetworkSettings.Networks}}}'
)


class Deadline:
    def __init__(self, seconds):
        self.end = time.monotonic() + seconds

    def remaining(self):
        return max(0.0, self.end - time.monotonic())


class Result:
    def __init__(self):
        self.code = None
        self.timed_out = False
        self.over_limit = False
        self.stdout = b""
        self.stderr = b""

    @property
    def ok(self):
        return self.code == 0 and not self.timed_out and not self.over_limit


class TailBuffer:
    """Keeps only the newest `keep` bytes while counting everything read."""

    def __init__(self, keep):
        self.keep = keep
        self.data = bytearray()
        self.total = 0

    def add(self, chunk):
        self.total += len(chunk)
        self.data += chunk
        if len(self.data) > self.keep:
            del self.data[:len(self.data) - self.keep]


def kill_group(proc):
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


def run(argv, deadline, limits, tail=False):
    """Runs argv with per-stream byte limits and the shared deadline.

    limits is (stdout_limit, stderr_limit). With tail=False, output beyond a
    limit stops the command and marks over_limit. With tail=True the newest
    LOG_KEEP bytes are retained and the limit caps how much is read in total.
    """
    result = Result()
    if deadline.remaining() <= 0:
        result.timed_out = True
        return result
    try:
        proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, start_new_session=True)
    except OSError:
        result.code = 127
        return result

    buffers = {proc.stdout: TailBuffer(LOG_KEEP) if tail else bytearray(),
               proc.stderr: TailBuffer(LOG_KEEP) if tail else bytearray()}
    caps = {proc.stdout: limits[0], proc.stderr: limits[1]}
    sel = selectors.DefaultSelector()
    for stream in buffers:
        os.set_blocking(stream.fileno(), False)
        sel.register(stream, selectors.EVENT_READ)

    try:
        while sel.get_map():
            timeout = deadline.remaining()
            if timeout <= 0:
                result.timed_out = True
                break
            for key, _ in sel.select(timeout):
                stream = key.fileobj
                buf = buffers[stream]
                used = buf.total if tail else len(buf)
                room = caps[stream] - used
                try:
                    chunk = os.read(stream.fileno(), min(64 * KIB, room + 1))
                except BlockingIOError:
                    continue
                if not chunk:
                    sel.unregister(stream)
                    continue
                if len(chunk) > room:
                    chunk = chunk[:room]
                    result.over_limit = True
                if tail:
                    buf.add(chunk)
                else:
                    buf += chunk
                if result.over_limit:
                    break
            if result.over_limit:
                break
    finally:
        sel.close()
        if result.timed_out or result.over_limit:
            kill_group(proc)
        try:
            result.code = proc.wait(timeout=max(0.5, deadline.remaining()))
        except subprocess.TimeoutExpired:
            kill_group(proc)
            result.timed_out = True
            result.code = proc.wait()
        proc.stdout.close()
        proc.stderr.close()

    def data(buf):
        return bytes(buf.data if tail else buf)
    result.stdout = data(buffers[proc.stdout])
    result.stderr = data(buffers[proc.stderr])
    return result


def complete_lines(data):
    """Drops a trailing partial line left by a truncated read."""
    text = data.decode("utf-8", "replace")
    return text if text.endswith("\n") else text[:text.rfind("\n") + 1]


def snapshot():
    deadline = Deadline(SNAPSHOT_DEADLINE)
    errors = []
    out = ["==DOCKER=="]

    version = run(["docker", "version", "--format", "{{.Server.Version}}"],
                  deadline, (SMALL_LIMIT, SMALL_LIMIT))
    version_text = version.stdout.decode("utf-8", "replace").strip().splitlines()
    if version.ok and version_text and re.match(r"^[A-Za-z0-9.+~-]{1,64}$", version_text[0]):
        out.append(version_text[0])
    else:
        out.append("unavailable")
        if version.timed_out:
            errors.append("Docker did not respond in time.")

    out.append("==HOST==")
    mem = 0
    try:
        with open("/proc/meminfo") as meminfo:
            for line in meminfo:
                if line.startswith("MemTotal:"):
                    mem = int(line.split()[1]) * 1024
                    break
    except (OSError, ValueError, IndexError):
        pass
    out.append(str(mem))
    out.append("==INSPECT==")

    stats_lines = []
    if out[1] != "unavailable":
        ps = run(["docker", "ps", "-aq", "--no-trunc"], deadline, (SMALL_LIMIT, SMALL_LIMIT))
        ids = [i for i in complete_lines(ps.stdout).split() if ID_RE.match(i)]
        if ps.timed_out:
            errors.append("Docker did not respond in time.")
        elif ps.over_limit:
            errors.append("Too many containers to list.")
        if ids:
            inspect = run(["docker", "inspect", "--format", INSPECT_FORMAT, "--"] + ids,
                          deadline, (INSPECT_LIMIT, SMALL_LIMIT))
            if inspect.over_limit:
                errors.append("Docker metadata exceeded the size limit; some containers are hidden.")
            elif inspect.timed_out:
                errors.append("Docker metadata timed out; some containers may be hidden.")
            out.extend(complete_lines(inspect.stdout).splitlines())

            stats = run(["docker", "stats", "--no-stream", "--format",
                         "{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}"],
                        deadline, (STATS_LIMIT, SMALL_LIMIT))
            if stats.over_limit or stats.timed_out:
                errors.append("Container statistics were incomplete.")
            stats_lines = complete_lines(stats.stdout).splitlines()

    out.append("==STATS==")
    out.extend(stats_lines)
    out.append("==ERROR==")
    out.extend(dict.fromkeys(errors))
    sys.stdout.write("\n".join(out) + "\n")


def clean_log_lines(data):
    lines = []
    for line in ANSI_RE.sub("", data.decode("utf-8", "replace")).split("\n"):
        line = line.rstrip("\r")
        if not line:
            continue
        if len(line) > LOG_LINE_CHARS:
            line = line[:LOG_LINE_CHARS] + " … [line truncated]"
        lines.append(line)
    return lines


def logs(container_id):
    if not ID_RE.match(container_id):
        return emit(2, "Invalid container id.")
    deadline = Deadline(LOGS_DEADLINE)
    result = run(["docker", "logs", "--tail", str(LOG_LINES), "--timestamps", "--", container_id],
                 deadline, (LOG_READ_LIMIT, LOG_READ_LIMIT), tail=True)
    # Docker sends application stderr separately. Timestamps restore chronology.
    lines = sorted(clean_log_lines(result.stdout) + clean_log_lines(result.stderr))[-LOG_LINES:]
    text = "\n".join(lines)[-LOG_KEEP:]
    notes = []
    if result.timed_out:
        notes.append("Docker logs timed out; showing what was read.")
    if result.over_limit:
        notes.append("Logs exceeded %d MiB; showing the newest part read." % (LOG_READ_LIMIT // MIB))
    if result.code not in (0, None) and not (result.timed_out or result.over_limit):
        notes.append("Docker logs failed (%d)" % result.code)
    emit(0 if result.ok else 1, "\n".join(notes + [text or "No logs available."]))


TIMESTAMP_RE = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d{1,9}))?Z (.*)$")


def split_timestamp(line):
    """Returns (sort key, local HH:MM:SS.mmm, message) for a --timestamps line.

    Docker trims trailing zeros from the fraction, so it is padded before
    sorting; plain string order would misplace e.g. .5 against .45.
    """
    match = TIMESTAMP_RE.match(line)
    if not match:
        return ("", "", line)
    base, fraction, message = match.group(1), match.group(2) or "", match.group(3)
    fraction = fraction.ljust(9, "0")
    try:
        local = datetime.fromisoformat(base + "+00:00").astimezone()
        shown = local.strftime("%H:%M:%S") + "." + fraction[:3]
    except ValueError:
        shown = ""
    return (base + "." + fraction, shown, message)


def group_logs(ids):
    if not ids or len(ids) > GROUP_LOG_CONTAINERS or not all(ID_RE.match(i) for i in ids):
        return emit(2, "Invalid container ids.")
    deadline = Deadline(LOGS_DEADLINE)

    def fetch(container_id):
        return run(["docker", "logs", "--tail", str(LOG_LINES), "--timestamps", "--", container_id],
                   deadline, (GROUP_LOG_READ_LIMIT, GROUP_LOG_READ_LIMIT), tail=True)

    with ThreadPoolExecutor(max_workers=min(8, len(ids))) as pool:
        results = list(pool.map(fetch, ids))

    entries = []
    for index, result in enumerate(results):
        for line in clean_log_lines(result.stdout) + clean_log_lines(result.stderr):
            key, shown, message = split_timestamp(line)
            entries.append((key, index, shown, message))
    # Stable sort keeps each container's own order for identical timestamps.
    entries.sort(key=lambda e: e[0])
    entries = entries[-GROUP_LOG_LINES:]

    notes = []
    if any(r.timed_out for r in results):
        notes.append("Some container logs timed out; showing what was read.")
    if any(r.over_limit for r in results):
        notes.append("Some logs exceeded %d MiB; showing the newest part read." % (GROUP_LOG_READ_LIMIT // MIB))
    failed = [ids[i][:12] for i, r in enumerate(results)
              if r.code not in (0, None) and not (r.timed_out or r.over_limit)]
    if failed:
        notes.append("Docker logs failed for " + ", ".join(failed))
    ok = all(r.ok for r in results)
    sys.stdout.write(json.dumps({"code": 0 if ok else 1, "text": "\n".join(notes),
                                 "lines": [[e[1], e[2], e[3]] for e in entries]}) + "\n")


def compose_project_name(path, text):
    """Mirrors Compose's naming: top-level `name:`, else the folder name."""
    match = re.search(r"^name:\s*[\"']?([A-Za-z0-9][A-Za-z0-9_.-]*)[\"']?\s*$", text, re.M)
    if match and "${" not in match.group(0):
        return match.group(1).lower()
    base = re.sub(r"[^a-z0-9_-]", "", os.path.basename(os.path.dirname(path)).lower())
    return base.lstrip("_-") or "default"


def compose_services(text):
    """Top-level service keys, read by indentation; good enough for a summary."""
    services, indent, inside = [], None, False
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line[0].isspace():
            inside = line.rstrip().rstrip(":") == "services" or line.startswith("services:")
            indent = None
            continue
        if not inside:
            continue
        width = len(line) - len(line.lstrip())
        if indent is None:
            indent = width
        match = re.match(r"^\s*[\"']?([A-Za-z0-9][A-Za-z0-9_.-]*)[\"']?\s*:", line)
        if width == indent and match:
            services.append(match.group(1))
    return services[:50]


def read_compose(path):
    try:
        with open(path, "rb") as handle:
            return handle.read(COMPOSE_READ_LIMIT).decode("utf-8", "replace")
    except OSError:
        return ""


def scan_compose_files(roots, deadline):
    found, visited, truncated = [], 0, False
    for root in roots:
        root = os.path.realpath(os.path.expanduser(root))
        if not os.path.isdir(root):
            continue
        stack = [(root, 0)]
        while stack:
            if deadline.remaining() <= 0 or visited >= SCAN_MAX_DIRS or len(found) >= SCAN_MAX_PROJECTS:
                truncated = True
                break
            folder, depth = stack.pop()
            visited += 1
            try:
                entries = list(os.scandir(folder))
            except OSError:
                continue
            names = {e.name for e in entries if e.is_file(follow_symlinks=False)}
            compose = next((n for n in COMPOSE_FILES if n in names), None)
            if compose:
                found.append(os.path.join(folder, compose))
            if depth >= SCAN_DEPTH:
                continue
            for entry in entries:
                if (entry.is_dir(follow_symlinks=False) and not entry.name.startswith(".")
                        and entry.name not in SKIP_DIRS):
                    stack.append((entry.path, depth + 1))
    return found, truncated


def projects(roots):
    deadline = Deadline(PROJECTS_DEADLINE)
    notes = []
    by_name = {}

    # Projects Docker has containers for, running or stopped.
    listed = run(["docker", "compose", "ls", "--all", "--format", "json"],
                 deadline, (SMALL_LIMIT * 4, SMALL_LIMIT))
    try:
        known = json.loads(listed.stdout.decode("utf-8", "replace") or "[]") if listed.ok else []
    except ValueError:
        known = []
    for item in known if isinstance(known, list) else []:
        name = str(item.get("Name") or "")
        files = [f for f in str(item.get("ConfigFiles") or "").split(",") if f]
        if not NAME_RE.match(name) or not files:
            continue
        by_name[name] = {"name": name, "files": files, "dir": os.path.dirname(files[0]),
                         "status": str(item.get("Status") or "")[:80], "services": []}

    files, truncated = scan_compose_files(roots, deadline)
    if truncated:
        notes.append("Project search stopped early; narrow projectDirs to find everything.")
    for path in files:
        text = read_compose(path)
        name = compose_project_name(path, text)
        project = by_name.get(name)
        if project is None:
            by_name[name] = {"name": name, "files": [path], "dir": os.path.dirname(path),
                             "status": "", "services": compose_services(text)}
        elif os.path.realpath(path) in [os.path.realpath(f) for f in project["files"]]:
            project["services"] = compose_services(text)

    for project in by_name.values():
        if not project["services"]:
            project["services"] = compose_services(read_compose(project["files"][0]))
        project["available"] = all(os.path.isfile(f) for f in project["files"])
    result = sorted(by_name.values(), key=lambda p: p["name"])
    sys.stdout.write(json.dumps({"code": 0, "text": "\n".join(notes), "projects": result}) + "\n")


def compose_up(files):
    if not files or len(files) > 8:
        return emit(2, "Invalid compose files.")
    for path in files:
        if (not os.path.isabs(path) or os.path.basename(path) not in COMPOSE_FILES
                or not os.path.isfile(path)):
            return emit(2, "Not a Compose file: " + path[:300])
    argv = ["docker", "compose"]
    for path in files:
        argv += ["-f", path]
    argv += ["--project-directory", os.path.dirname(files[0]), "up", "-d"]
    result = run(argv, Deadline(UP_DEADLINE), (SMALL_LIMIT, SMALL_LIMIT), tail=True)
    if result.ok:
        return emit(0, "")
    message = ANSI_RE.sub("", (result.stderr or result.stdout).decode("utf-8", "replace")).strip()
    if result.timed_out:
        message = "docker compose up did not finish within %d minutes." % (UP_DEADLINE // 60)
    emit(result.code or 1, message[-2000:] or "docker compose up failed.")


def command(argv, deadline_seconds):
    result = run(argv, Deadline(deadline_seconds), (SMALL_LIMIT, SMALL_LIMIT))
    if result.ok:
        return emit(0, "")
    message = (result.stderr or result.stdout).decode("utf-8", "replace").strip()[:2000]
    if result.timed_out:
        message = "Command timed out."
    emit(result.code or 1, ANSI_RE.sub("", message) or "Command failed.")


def action(verb, ids):
    if verb not in ("start", "stop", "restart") or not ids or not all(ID_RE.match(i) for i in ids):
        return emit(2, "Invalid action.")
    command(["docker", verb, "--"] + ids, ACTION_DEADLINE)


def memory(name, mb):
    if not NAME_RE.match(name) or not re.match(r"^[0-9]{1,9}$", mb):
        return emit(2, "Invalid memory update.")
    command(["docker", "update", "--memory", mb + "m", "--memory-swap", "-1", "--", name],
            ACTION_DEADLINE)


def emit(code, text):
    sys.stdout.write(json.dumps({"code": code, "text": text}) + "\n")


def main(argv):
    if argv[:1] == ["snapshot"] and len(argv) == 1:
        snapshot()
    elif argv[:1] == ["logs"] and len(argv) == 2:
        logs(argv[1])
    elif argv[:1] == ["grouplogs"] and len(argv) >= 2:
        group_logs(argv[1:])
    elif argv[:1] == ["action"] and len(argv) >= 3:
        action(argv[1], argv[2:])
    elif argv[:1] == ["memory"] and len(argv) == 3:
        memory(argv[1], argv[2])
    elif argv[:1] == ["projects"]:
        projects(argv[1:])
    elif argv[:1] == ["up"] and len(argv) >= 2:
        compose_up(argv[1:])
    else:
        emit(2, "Usage: docker-helper.py snapshot | logs <id> | grouplogs <id>... | action <verb> <id>... | memory <name> <mb> | projects <dir>... | up <compose-file>...")


if __name__ == "__main__":
    main(sys.argv[1:])
