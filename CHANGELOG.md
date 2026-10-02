# Changelog

## Unreleased

- Security: Ask agent no longer puts Compose service/project labels or label-derived URLs into the instruction prompt (marketplace hold omacom/omarchy-plugin-marketplace#9659 / HANCORE). The prompt keeps container name, image, status, and validated ids; the agent can read the rest via `docker inspect`.

## Unreleased

- Published ports: the container Overview lists every host-published port and what answers on it (web page, API, other HTTP, not HTTP), each HTTP port clickable. Web pages become the group and container Open buttons, labelled by service, so links work on any port instead of a fixed list. Uses the new `docker-helper.py probe` command (1 s per port, 4 KiB read, re-checked after a minute).

## Unreleased

- Available projects: the home page lists Compose projects that are not running, found under `projectDirs` (default `~`) or known to Docker, with a Start button that runs `docker compose up -d`. Uses the new `docker-helper.py projects` and `up` commands, with a bounded folder search and a 10-minute start deadline.

## 0.3.0

- Ask agent: a button on group and container pages opens your default Omarchy agent (`omarchy agent prompt`) asking what that software is for. The prompt carries names, images, status, and URLs, and tells the agent to use only read-only Docker commands.
- Power controls: a RUNNING switch on each container's Settings page starts or stops it, with a Restart action beside it. Both run through `docker-helper.py` like the ⋯ menu actions and are enabled only when they apply to the container's current state.

## 0.2.0

- Group logs: merge every container's logs in a group into one timeline, color-coded per container from the theme's palette, with click-to-hide filtering and a live follow mode. Fetched in parallel through `docker-helper.py grouplogs` under the same deadline and per-stream limits.

## 0.1.1

Security hardening from marketplace review.

- All Docker access runs through `docker-helper.py`, which enforces an overall deadline and per-stream byte limits and kills commands that exceed them.
- Logs are capped while reading: bytes per stream, newest 60,000 characters, and 2,000 characters per line.
- Every text element renders as plain text, so container names, images, and labels cannot trigger rich-text formatting.
- Lifecycle and memory commands are validated again by the helper before Docker runs.

## 0.1.0

Initial Docker Monitor release, derived from devgtv's MIT-licensed Docker widget.

- Active-group list with host CPU/RAM, aligned metrics, service icons, and attention indicators.
- Separate group/container pages with fixed headers and contextual action menus.
- Overview/Settings tabs, graphs, logs, custom names and URLs, and RAM controls.
- Internal Docker IPv4/IPv6 addresses, including multiple networks.
- Standalone identity and preferences, demo-data previews, and updated documentation.
