## Server-rendered HTML templates for the dootd dashboard.
## Each function returns a string of HTML. Uses inline CSS via a single
## embedded stylesheet in the layout. No JS frameworks, no SPA.

import std/[strutils]
import ./dootd_types
import ./dootd_stats

proc escapeHtml*(s: string): string =
  ## Escape HTML special characters to prevent XSS.
  ## Replaces &, <, >, and " with their HTML entity equivalents.
  result = ""
  for c in s:
    case c
    of '&': result.add("&amp;")
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    of '"': result.add("&quot;")
    else: result.add(c)

const DashboardCSS* = """
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    background: #f5f7fa;
    color: #333;
    line-height: 1.6;
  }
  .nav {
    background: #1a1a2e;
    padding: 0.75rem 2rem;
    display: flex;
    align-items: center;
    gap: 2rem;
  }
  .nav-brand {
    color: #e94560;
    font-weight: 700;
    font-size: 1.25rem;
    text-decoration: none;
  }
  .nav-links { display: flex; gap: 1.5rem; }
  .nav-links a {
    color: #ccc;
    text-decoration: none;
    font-size: 0.9rem;
  }
  .nav-links a:hover { color: #fff; }
  .nav-right { margin-left: auto; }
  .container { max-width: 1100px; margin: 2rem auto; padding: 0 1.5rem; }
  .card {
    background: #fff;
    border-radius: 8px;
    padding: 1.5rem;
    margin-bottom: 1.5rem;
    box-shadow: 0 2px 4px rgba(0,0,0,0.05);
  }
  .card h2 { margin-bottom: 1rem; font-size: 1.25rem; }
  .btn {
    display: inline-block;
    padding: 0.5rem 1rem;
    border-radius: 4px;
    text-decoration: none;
    font-size: 0.875rem;
    cursor: pointer;
    border: none;
    font-family: inherit;
  }
  .btn-primary { background: #e94560; color: #fff; }
  .btn-primary:hover { background: #d63851; }
  .btn-secondary { background: #6c757d; color: #fff; }
  .btn-secondary:hover { background: #5a6268; }
  .btn-danger { background: #dc3545; color: #fff; }
  .btn-danger:hover { background: #c82333; }
  .btn-success { background: #28a745; color: #fff; }
  .btn-success:hover { background: #218838; }
  table { width: 100%; border-collapse: collapse; }
  th, td { padding: 0.75rem; text-align: left; border-bottom: 1px solid #eee; }
  th { font-weight: 600; color: #555; font-size: 0.85rem; text-transform: uppercase; }
  .status-badge {
    display: inline-block;
    padding: 0.2rem 0.6rem;
    border-radius: 12px;
    font-size: 0.75rem;
    font-weight: 600;
  }
  .status-running { background: #d4edda; color: #155724; }
  .status-stopped { background: #f8d7da; color: #721c24; }
  .status-error { background: #f5c6cb; color: #721c24; }
  .status-deploying { background: #fff3cd; color: #856404; }
  .form-group { margin-bottom: 1rem; }
  .form-group label { display: block; margin-bottom: 0.3rem; font-weight: 500; font-size: 0.9rem; }
  .form-group input, .form-group textarea, .form-group select {
    width: 100%; padding: 0.5rem; border: 1px solid #ddd;
    border-radius: 4px; font-size: 0.9rem; font-family: inherit;
  }
  .form-group textarea { min-height: 100px; resize: vertical; }
  .alert { padding: 0.75rem 1rem; border-radius: 4px; margin-bottom: 1rem; }
  .alert-success { background: #d4edda; color: #155724; }
  .alert-error { background: #f8d7da; color: #721c24; }
  .alert-info { background: #d1ecf1; color: #0c5460; }
  .stats-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 1rem; }
  .stat-card { background: #fff; border-radius: 8px; padding: 1.25rem; text-align: center; box-shadow: 0 2px 4px rgba(0,0,0,0.05); }
  .stat-value { font-size: 2rem; font-weight: 700; color: #1a1a2e; }
  .stat-label { font-size: 0.85rem; color: #6c757d; margin-top: 0.25rem; }
  .log-container { background: #1a1a2e; color: #e0e0e0; border-radius: 8px; padding: 1rem; font-family: 'Courier New', monospace; font-size: 0.8rem; max-height: 600px; overflow-y: auto; }
  .log-line { padding: 0.15rem 0; white-space: pre-wrap; word-break: break-all; }
  .log-line .ts { color: #6c757d; }
  .log-line .stream-stdout { color: #28a745; }
  .log-line .stream-stderr { color: #dc3545; }
  .login-container { max-width: 400px; margin: 4rem auto; padding: 0 1.5rem; }
  .login-card { background: #fff; border-radius: 8px; padding: 2rem; box-shadow: 0 4px 12px rgba(0,0,0,0.1); text-align: center; }
  .login-card h1 { color: #e94560; margin-bottom: 0.5rem; }
  .login-card p { color: #6c757d; margin-bottom: 1.5rem; }
  .actions { display: flex; gap: 0.5rem; align-items: center; }
"""

proc renderLayout*(title: string, bodyContent: string, isLoggedIn: bool = true, csrfToken: string = ""): string =
  ## Wraps content in a full HTML page with nav bar and embedded CSS.
  result = "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n"
  result.add("  <meta charset=\"UTF-8\">\n")
  result.add("  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n")
  result.add("  <title>" & escapeHtml(title) & " - Dootd</title>\n")
  result.add("  <style>" & DashboardCSS & "</style>\n")
  result.add("</head>\n<body>\n")

  if isLoggedIn:
    result.add("<nav class=\"nav\">\n")
    result.add("  <a href=\"/\" class=\"nav-brand\">dootd</a>\n")
    result.add("  <div class=\"nav-links\">\n")
    result.add("    <a href=\"/\">Apps</a>\n")
    result.add("    <a href=\"/stats\">Stats</a>\n")
    result.add("    <a href=\"/settings\">Settings</a>\n")
    result.add("  </div>\n")
    result.add("  <div class=\"nav-right\">\n")
    result.add("    <form method=\"POST\" action=\"/logout\" style=\"display:inline\">\n")
    result.add("      <input type=\"hidden\" name=\"csrf_token\" value=\"" & csrfToken & "\">\n")
    result.add("      <button type=\"submit\" class=\"btn btn-secondary\">Logout</button>\n")
    result.add("    </form>\n")
    result.add("  </div>\n")
    result.add("</nav>\n")

  result.add(bodyContent)
  result.add("\n</body>\n</html>")

proc renderLoginPage*(error: string = ""): string =
  ## Render the login form page.
  var body = "<div class=\"login-container\">\n"
  body.add("  <div class=\"login-card\">\n")
  body.add("    <h1>dootd</h1>\n")
  body.add("    <p>Production Dashboard</p>\n")
  if error.len > 0:
    body.add("    <div class=\"alert alert-error\">" & escapeHtml(error) & "</div>\n")
  body.add("    <form method=\"POST\" action=\"/login\">\n")
  body.add("      <div class=\"form-group\">\n")
  body.add("        <input type=\"password\" name=\"password\" placeholder=\"Admin password\" required autofocus>\n")
  body.add("      </div>\n")
  body.add("      <button type=\"submit\" class=\"btn btn-primary\" style=\"width:100%\">Login</button>\n")
  body.add("    </form>\n")
  body.add("  </div>\n")
  body.add("</div>\n")
  result = renderLayout("Login", body, isLoggedIn = false)

proc statusClass(status: AppStatus): string =
  case status
  of asRunning: "status-running"
  of asStopped: "status-stopped"
  of asError: "status-error"
  of asDeploying: "status-deploying"

proc renderAppList*(apps: seq[AppConfig], csrfToken: string = ""): string =
  ## Render the app list page showing all managed applications.
  var body = "<div class=\"container\">\n"
  body.add("  <div class=\"card\">\n")
  body.add("    <div style=\"display:flex;justify-content:space-between;align-items:center;margin-bottom:1rem\">\n")
  body.add("      <h2>Managed Applications</h2>\n")
  body.add("      <a href=\"/apps/new\" class=\"btn btn-primary\">New App</a>\n")
  body.add("    </div>\n")

  if apps.len == 0:
    body.add("    <p style=\"color:#6c757d\">No applications configured yet.</p>\n")
  else:
    body.add("    <table>\n")
    body.add("      <thead><tr><th>Name</th><th>Hostname</th><th>Port</th><th>Status</th><th>Actions</th></tr></thead>\n")
    body.add("      <tbody>\n")
    for app in apps:
      body.add("        <tr>\n")
      body.add("          <td><a href=\"/apps/" & $app.id & "\">" & escapeHtml(app.name) & "</a></td>\n")
      body.add("          <td>" & escapeHtml(app.hostname) & "</td>\n")
      body.add("          <td>" & $app.internalPort & "</td>\n")
      body.add("          <td><span class=\"status-badge " & statusClass(app.status) & "\">" & $app.status & "</span></td>\n")
      body.add("          <td class=\"actions\">\n")
      body.add("            <form method=\"POST\" action=\"/apps/" & $app.id & "/deploy\" style=\"display:inline\">\n")
      body.add("              <input type=\"hidden\" name=\"csrf_token\" value=\"" & csrfToken & "\">\n")
      body.add("              <button type=\"submit\" class=\"btn btn-success\">Deploy</button>\n")
      body.add("            </form>\n")
      body.add("            <a href=\"/apps/" & $app.id & "/logs\" class=\"btn btn-secondary\">Logs</a>\n")
      body.add("          </td>\n")
      body.add("        </tr>\n")
    body.add("      </tbody>\n")
    body.add("    </table>\n")

  body.add("  </div>\n")
  body.add("</div>\n")
  result = renderLayout("Apps", body)

proc renderAppForm*(app: AppConfig = AppConfig(), isEdit: bool = false, csrfToken: string = ""): string =
  ## Render the form for creating or editing an app.
  let title = if isEdit: "Edit App" else: "New App"
  let action = if isEdit: "/apps/" & $app.id & "/update" else: "/apps"
  let buttonText = if isEdit: "Update App" else: "Create App"

  var body = "<div class=\"container\">\n"
  body.add("  <div class=\"card\">\n")
  body.add("    <h2>" & title & "</h2>\n")
  body.add("    <form method=\"POST\" action=\"" & action & "\">\n")
  body.add("      <input type=\"hidden\" name=\"csrf_token\" value=\"" & csrfToken & "\">\n")
  body.add("      <div class=\"form-group\">\n")
  body.add("        <label for=\"name\">App Name</label>\n")
  body.add("        <input type=\"text\" id=\"name\" name=\"name\" value=\"" & escapeHtml(app.name) & "\" required>\n")
  body.add("      </div>\n")
  body.add("      <div class=\"form-group\">\n")
  body.add("        <label for=\"hostname\">Hostname</label>\n")
  body.add("        <input type=\"text\" id=\"hostname\" name=\"hostname\" value=\"" & escapeHtml(app.hostname) & "\" placeholder=\"myapp.example.com\" required>\n")
  body.add("      </div>\n")
  body.add("      <div class=\"form-group\">\n")
  body.add("        <label for=\"github_url\">GitHub URL</label>\n")
  body.add("        <input type=\"text\" id=\"github_url\" name=\"github_url\" value=\"" & escapeHtml(app.githubUrl) & "\" placeholder=\"https://github.com/user/repo\" required>\n")
  body.add("      </div>\n")
  body.add("      <div class=\"form-group\">\n")
  body.add("        <label for=\"pat\">Personal Access Token (PAT)</label>\n")
  body.add("        <input type=\"password\" id=\"pat\" name=\"pat\" value=\"" & escapeHtml(app.pat) & "\">\n")
  body.add("      </div>\n")
  body.add("      <div class=\"form-group\">\n")
  body.add("        <label for=\"branch\">Branch</label>\n")
  body.add("        <input type=\"text\" id=\"branch\" name=\"branch\" value=\"" & escapeHtml(if app.branch.len > 0: app.branch else: "main") & "\">\n")
  body.add("      </div>\n")
  body.add("      <div class=\"form-group\">\n")
  body.add("        <label for=\"env_vars\">Environment Variables (one KEY=VALUE per line)</label>\n")
  body.add("        <textarea id=\"env_vars\" name=\"env_vars\" placeholder=\"DATABASE_URL=sqlite:app.db&#10;PORT=3001\">" & escapeHtml(app.envVars) & "</textarea>\n")
  body.add("      </div>\n")
  body.add("      <div class=\"form-group\">\n")
  body.add("        <label for=\"memory_limit\">Memory Limit (MB, 0 = unlimited)</label>\n")
  body.add("        <input type=\"number\" id=\"memory_limit\" name=\"memory_limit\" value=\"" & $app.memoryLimit & "\" min=\"0\">\n")
  body.add("      </div>\n")
  body.add("      <div class=\"form-group\">\n")
  body.add("        <label for=\"cpu_shares\">CPU Shares (0 = default)</label>\n")
  body.add("        <input type=\"number\" id=\"cpu_shares\" name=\"cpu_shares\" value=\"" & $app.cpuShares & "\" min=\"0\">\n")
  body.add("      </div>\n")
  body.add("      <button type=\"submit\" class=\"btn btn-primary\">" & buttonText & "</button>\n")
  if isEdit:
    body.add("      <a href=\"/apps/" & $app.id & "\" class=\"btn btn-secondary\" style=\"margin-left:0.5rem\">Cancel</a>\n")
  else:
    body.add("      <a href=\"/\" class=\"btn btn-secondary\" style=\"margin-left:0.5rem\">Cancel</a>\n")
  body.add("    </form>\n")
  body.add("  </div>\n")
  body.add("</div>\n")
  result = renderLayout(title, body)

proc renderAppDetail*(app: AppConfig, recentLogs: seq[tuple[timestamp, stream, message: string]] = @[], csrfToken: string = ""): string =
  ## Render the app detail page with status, info, and recent logs.
  var body = "<div class=\"container\">\n"
  body.add("  <div class=\"card\">\n")
  body.add("    <div style=\"display:flex;justify-content:space-between;align-items:center;margin-bottom:1rem\">\n")
  body.add("      <h2>" & escapeHtml(app.name) & "</h2>\n")
  body.add("      <span class=\"status-badge " & statusClass(app.status) & "\">" & $app.status & "</span>\n")
  body.add("    </div>\n")
  body.add("    <table>\n")
  body.add("      <tr><td><strong>Hostname</strong></td><td>" & escapeHtml(app.hostname) & "</td></tr>\n")
  body.add("      <tr><td><strong>GitHub URL</strong></td><td>" & escapeHtml(app.githubUrl) & "</td></tr>\n")
  body.add("      <tr><td><strong>Branch</strong></td><td>" & escapeHtml(app.branch) & "</td></tr>\n")
  body.add("      <tr><td><strong>Internal Port</strong></td><td>" & $app.internalPort & "</td></tr>\n")
  body.add("      <tr><td><strong>Memory Limit</strong></td><td>" & (if app.memoryLimit > 0: $app.memoryLimit & " MB" else: "Unlimited") & "</td></tr>\n")
  body.add("      <tr><td><strong>CPU Shares</strong></td><td>" & (if app.cpuShares > 0: $app.cpuShares else: "Default") & "</td></tr>\n")
  body.add("    </table>\n")
  body.add("    <div style=\"margin-top:1rem\" class=\"actions\">\n")
  body.add("      <form method=\"POST\" action=\"/apps/" & $app.id & "/deploy\" style=\"display:inline\">\n")
  body.add("        <input type=\"hidden\" name=\"csrf_token\" value=\"" & csrfToken & "\">\n")
  body.add("        <button type=\"submit\" class=\"btn btn-success\">Deploy</button>\n")
  body.add("      </form>\n")
  body.add("      <a href=\"/apps/" & $app.id & "/edit\" class=\"btn btn-secondary\">Edit</a>\n")
  body.add("      <a href=\"/apps/" & $app.id & "/logs\" class=\"btn btn-secondary\">Logs</a>\n")
  body.add("      <form method=\"POST\" action=\"/apps/" & $app.id & "/delete\" style=\"display:inline\" onsubmit=\"return confirm('Delete this app?')\">\n")
  body.add("        <input type=\"hidden\" name=\"csrf_token\" value=\"" & csrfToken & "\">\n")
  body.add("        <button type=\"submit\" class=\"btn btn-danger\">Delete</button>\n")
  body.add("      </form>\n")
  body.add("    </div>\n")
  body.add("  </div>\n")

  if recentLogs.len > 0:
    body.add("  <div class=\"card\">\n")
    body.add("    <h2>Recent Logs</h2>\n")
    body.add("    <div class=\"log-container\">\n")
    for log in recentLogs:
      let streamClass = if log.stream == "stdout": "stream-stdout" else: "stream-stderr"
      body.add("      <div class=\"log-line\"><span class=\"ts\">[" & escapeHtml(log.timestamp) & "]</span> <span class=\"" & streamClass & "\">[" & log.stream & "]</span> " & escapeHtml(log.message) & "</div>\n")
    body.add("    </div>\n")
    body.add("  </div>\n")

  body.add("</div>\n")
  result = renderLayout(escapeHtml(app.name), body)

proc renderLogsPage*(appName: string, logs: seq[tuple[timestamp, stream, message: string]], filter: string = ""): string =
  ## Render the log viewer page with search filtering.
  var body = "<div class=\"container\">\n"
  body.add("  <div class=\"card\">\n")
  body.add("    <h2>Logs: " & escapeHtml(appName) & "</h2>\n")
  body.add("    <form method=\"GET\" style=\"margin-bottom:1rem\">\n")
  body.add("      <div style=\"display:flex;gap:0.5rem\">\n")
  body.add("        <input type=\"text\" name=\"search\" value=\"" & escapeHtml(filter) & "\" placeholder=\"Filter logs...\" style=\"flex:1;padding:0.5rem;border:1px solid #ddd;border-radius:4px\">\n")
  body.add("        <button type=\"submit\" class=\"btn btn-primary\">Search</button>\n")
  body.add("      </div>\n")
  body.add("    </form>\n")
  body.add("    <div class=\"log-container\">\n")

  if logs.len == 0:
    body.add("      <div class=\"log-line\">No log entries found.</div>\n")
  else:
    for log in logs:
      let streamClass = if log.stream == "stdout": "stream-stdout" else: "stream-stderr"
      body.add("      <div class=\"log-line\"><span class=\"ts\">[" & escapeHtml(log.timestamp) & "]</span> <span class=\"" & streamClass & "\">[" & log.stream & "]</span> " & escapeHtml(log.message) & "</div>\n")

  body.add("    </div>\n")
  body.add("  </div>\n")
  body.add("</div>\n")
  result = renderLayout("Logs - " & escapeHtml(appName), body)

proc renderStatsPage*(stats: SystemStats): string =
  ## Render the server stats page with system metrics.
  var body = "<div class=\"container\">\n"
  body.add("  <div class=\"card\">\n")
  body.add("    <h2>System Statistics</h2>\n")
  body.add("    <div class=\"stats-grid\">\n")

  # Hostname
  body.add("      <div class=\"stat-card\">\n")
  body.add("        <div class=\"stat-value\">" & escapeHtml(stats.hostname) & "</div>\n")
  body.add("        <div class=\"stat-label\">Hostname</div>\n")
  body.add("      </div>\n")

  # Uptime
  body.add("      <div class=\"stat-card\">\n")
  body.add("        <div class=\"stat-value\">" & escapeHtml(stats.uptime) & "</div>\n")
  body.add("        <div class=\"stat-label\">Uptime</div>\n")
  body.add("      </div>\n")

  # CPU
  if stats.cpu.available:
    body.add("      <div class=\"stat-card\">\n")
    body.add("        <div class=\"stat-value\">" & formatFloat(stats.cpu.usagePercent, ffDecimal, 1) & "%</div>\n")
    body.add("        <div class=\"stat-label\">CPU Usage</div>\n")
    body.add("      </div>\n")
  else:
    body.add("      <div class=\"stat-card\">\n")
    body.add("        <div class=\"stat-value\">N/A</div>\n")
    body.add("        <div class=\"stat-label\">CPU Usage</div>\n")
    body.add("      </div>\n")

  # Memory
  if stats.memory.available:
    body.add("      <div class=\"stat-card\">\n")
    body.add("        <div class=\"stat-value\">" & $stats.memory.usedMb & " / " & $stats.memory.totalMb & " MB</div>\n")
    body.add("        <div class=\"stat-label\">Memory (" & formatFloat(stats.memory.usagePercent, ffDecimal, 1) & "%)</div>\n")
    body.add("      </div>\n")
  else:
    body.add("      <div class=\"stat-card\">\n")
    body.add("        <div class=\"stat-value\">N/A</div>\n")
    body.add("        <div class=\"stat-label\">Memory</div>\n")
    body.add("      </div>\n")

  # Disk
  if stats.disk.available:
    body.add("      <div class=\"stat-card\">\n")
    body.add("        <div class=\"stat-value\">" & formatFloat(stats.disk.usedGb, ffDecimal, 1) & " / " & formatFloat(stats.disk.totalGb, ffDecimal, 1) & " GB</div>\n")
    body.add("        <div class=\"stat-label\">Disk (" & formatFloat(stats.disk.usagePercent, ffDecimal, 1) & "%)</div>\n")
    body.add("      </div>\n")
  else:
    body.add("      <div class=\"stat-card\">\n")
    body.add("        <div class=\"stat-value\">N/A</div>\n")
    body.add("        <div class=\"stat-label\">Disk</div>\n")
    body.add("      </div>\n")

  body.add("    </div>\n")
  body.add("  </div>\n")
  body.add("</div>\n")
  result = renderLayout("Stats", body)

proc renderSettingsPage*(message: string = "", isError: bool = false, csrfToken: string = ""): string =
  ## Render the settings page with password change form.
  var body = "<div class=\"container\">\n"
  body.add("  <div class=\"card\">\n")
  body.add("    <h2>Settings</h2>\n")
  if message.len > 0:
    let alertClass = if isError: "alert-error" else: "alert-success"
    body.add("    <div class=\"alert " & alertClass & "\">" & escapeHtml(message) & "</div>\n")
  body.add("    <h3 style=\"margin-bottom:1rem;font-size:1rem\">Change Password</h3>\n")
  body.add("    <form method=\"POST\" action=\"/settings/password\">\n")
  body.add("      <input type=\"hidden\" name=\"csrf_token\" value=\"" & csrfToken & "\">\n")
  body.add("      <div class=\"form-group\">\n")
  body.add("        <label for=\"current_password\">Current Password</label>\n")
  body.add("        <input type=\"password\" id=\"current_password\" name=\"current_password\" required>\n")
  body.add("      </div>\n")
  body.add("      <div class=\"form-group\">\n")
  body.add("        <label for=\"new_password\">New Password</label>\n")
  body.add("        <input type=\"password\" id=\"new_password\" name=\"new_password\" required>\n")
  body.add("      </div>\n")
  body.add("      <div class=\"form-group\">\n")
  body.add("        <label for=\"confirm_password\">Confirm New Password</label>\n")
  body.add("        <input type=\"password\" id=\"confirm_password\" name=\"confirm_password\" required>\n")
  body.add("      </div>\n")
  body.add("      <button type=\"submit\" class=\"btn btn-primary\">Change Password</button>\n")
  body.add("    </form>\n")
  body.add("  </div>\n")
  body.add("</div>\n")
  result = renderLayout("Settings", body)
