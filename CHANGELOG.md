# Changelog

## 0.3.0

- Ask agent: a button on group and container pages opens your default Omarchy agent (`omarchy agent prompt`) asking what that software is for. The prompt carries names, images, status, and URLs, and tells the agent to use only read-only Docker commands.
- Power controls: Start, Stop, and Restart buttons on each container's Settings page, next to the RAM limit. They run through `docker-helper.py` like the ⋯ menu actions, and each button is enabled only when that action applies to the container's current state.

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
