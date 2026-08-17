## Core types for the dootd production daemon.
## Defines configuration, application state, and constants used
## throughout the daemon infrastructure.

type
  AppStatus* = enum
    asRunning = "running"
    asStopped = "stopped"
    asError = "error"
    asDeploying = "deploying"

  AppConfig* = object
    id*: int64
    name*: string
    hostname*: string
    githubUrl*: string
    pat*: string
    branch*: string
    envVars*: string          ## JSON-encoded key-value pairs
    internalPort*: int
    memoryLimit*: int         ## Memory limit in MB (0 = unlimited)
    cpuShares*: int           ## CPU shares (0 = default)
    status*: AppStatus

  DootdConfig* = object
    dataDir*: string
    dashboardPort*: int
    routerPort*: int
    binaryPath*: string

  DootdState* = object
    config*: DootdConfig
    apps*: seq[AppConfig]
    passwordHash*: string
    initialized*: bool

const
  DefaultDashboardPort* = 8080
  DefaultRouterPort* = 80
  DefaultDataDir* = "/var/lib/dootd"
  UserDataDir* = ".dootd"
  InternalPortStart* = 3001
  MaxApps* = 100
