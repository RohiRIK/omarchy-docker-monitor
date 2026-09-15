import json
import time
from pathlib import Path

def cpu():
    fields = list(map(int, Path("/proc/stat").read_text().splitlines()[0].split()[1:9]))
    return sum(fields), fields[3] + fields[4]

try:
    total_before, idle_before = cpu()
    time.sleep(0.2)
    total_after, idle_after = cpu()
    elapsed = total_after - total_before
    memory = {}
    for line in Path("/proc/meminfo").read_text().splitlines():
        key, value = line.split(":", 1)
        memory[key] = int(value.split()[0]) * 1024
    total = memory["MemTotal"]
    used = max(0, total - memory["MemAvailable"])
    percent = max(0, min(100, 100 * (1 - (idle_after - idle_before) / elapsed))) if elapsed > 0 else None
    print(json.dumps({"cpu": round(percent, 1) if percent is not None else None, "used": used, "total": total}))
except (OSError, ValueError, KeyError, IndexError):
    print("{}")
