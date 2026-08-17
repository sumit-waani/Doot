## Systemd service file generation for the dootd daemon.
## Generates unit file content and manages service installation.

import std/os

proc generateServiceFile*(binaryPath: string, dataDir: string): string =
  ## Generate the content of a systemd service unit file for dootd.
  result = """[Unit]
Description=Doot Production Daemon
After=network.target

[Service]
Type=simple
ExecStart=""" & binaryPath & """ --prod
Restart=always
RestartSec=5
WorkingDirectory=""" & dataDir & """
Environment=PATH=/usr/bin:/bin

[Install]
WantedBy=multi-user.target
"""

proc serviceFilePath*(): string =
  ## Return the standard systemd service file path.
  result = "/etc/systemd/system/dootd.service"

proc isServiceInstalled*(): bool =
  ## Check if the dootd systemd service file exists.
  result = fileExists(serviceFilePath())

proc installService*(binaryPath: string, dataDir: string): bool =
  ## Write the systemd service file and attempt to enable/start it.
  ## Returns true if the service file was written successfully.
  ## Gracefully handles environments where systemd is not available.
  let content = generateServiceFile(binaryPath, dataDir)
  let path = serviceFilePath()
  try:
    writeFile(path, content)
    # Attempt systemctl commands; these will fail gracefully in
    # environments without systemd (sandboxes, containers, etc.)
    discard execShellCmd("systemctl daemon-reload 2>/dev/null")
    discard execShellCmd("systemctl enable dootd 2>/dev/null")
    discard execShellCmd("systemctl start dootd 2>/dev/null")
    result = true
  except IOError, OSError:
    # Cannot write to /etc/systemd/system - not running as root
    # or systemd is not available
    result = false
