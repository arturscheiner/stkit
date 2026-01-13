# Syncthing Manager Tool (stkit.sh)

A simple and robust management script for running **Syncthing** in a rootless **Podman** container, with systemd integration.

It is designed to "map" your home directory into the container, so Syncthing works transparently with your files while keeping its own configuration and state separate.

## Features

- **Rootless Podman**: Runs entirely in user space (no root required).
- **Systemd Integration**: Auto-starts on boot/login via `systemd --user`.
- **Persistent Config**: Configuration matches standard XDG paths (`~/.local/share/syncthing`).
- **Clean Home Mapping**: Your `$HOME` is mapped to `/data` inside the container checking permissions.

## Prerequisites

- Linux with `systemd`.
- `podman` installed.
- (Optional) Linger enabled for your user if you want it to run when logged out:
  ```bash
  sudo loginctl enable-linger $USER
  ```

## Usage

Run the script directly:

```bash
./stkit.sh [COMMAND]
```

### Commands

| Command | Description |
| :--- | :--- |
| `install` | Installs systemd service, creates directories, and starts the container. |
| `update` | Pulls the latest image (`syncthing:2`) and restarts the service. |
| `start` | Starts the systemd service. |
| `stop` | Stops the systemd service. |
| `restart` | Restarts the service. |
| `check` | Shows service status, running container info, and directory checks. |
| `uninstall`| Removes the container and service, **keeping** your config/data. |
| `destroy` | **DANGER**: Removes container, service, AND configuration files. |

## Directory Structure

| Location on Host | Mapped to Container | Purpose |
| :--- | :--- | :--- |
| `~/.local/share/syncthing/config` | `/config` | Syncthing configuration (keys, config.xml). |
| `~/.local/share/syncthing/state` | `/state` | Database index. |
| `~` (Your Home) | `/data` | **Your Data**. |

> **IMPORTANT**: In the Syncthing Web GUI, when adding folders, always use paths starting with `/data`.
> Example: To sync `~/Documents`, add the folder path `/data/Documents`.

## Troubleshooting

- **"Container did not start correctly"**: The script checks startup health. Run `./stkit.sh check` or inspect logs with `podman logs syncthing`.
- **SELinux Errors**: The script uses `--security-opt label=disable` to allow accessing your home directory without relabeling it.
