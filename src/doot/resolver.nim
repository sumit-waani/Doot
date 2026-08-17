## Multi-file resolver for the Doot DSL compiler.
## Parses a project starting from app.do, follows mount directives,
## and recursively resolves template files from the views/ directory.

import std/os
import std/strutils
import std/sets
import tokens
import lexer
import parser
import ast

export parser

type
  Project* = object
    app*: DootNode              ## The nkApp node from app.do
    featureFiles*: seq[DootNode] ## Parsed feature files (top-level routes/groups)
    templates*: seq[DootNode]   ## Parsed template files
    errors*: seq[ParseError]    ## All collected errors

proc parseProject*(rootDir: string): Project =
  ## Parse a complete Doot project starting from app.do.
  ##
  ## 1. Reads and parses app.do from rootDir (RouteSchema mode)
  ## 2. For each MountNode, resolves the file path (mountPath + ".do") and parses it
  ## 3. Scans views/ directory recursively for .do files, parses each in Template mode
  ## 4. Returns a unified Project containing all parsed ASTs and collected errors
  var parsed: HashSet[string]
  result = Project(
    app: nil,
    featureFiles: @[],
    templates: @[],
    errors: @[]
  )

  # Step 1: Parse app.do
  let appPath = rootDir / "app.do"
  if not fileExists(appPath):
    result.errors.add(ParseError(
      file: appPath,
      line: 1,
      col: 1,
      message: "Entry point file 'app.do' not found in project directory",
      suggestion: "Create an app.do file in the project root"
    ))
    result.app = newAppNode(appPath, 1, 1)
    return

  let appSource = readFile(appPath)
  let appTokens = tokenize(appSource, appPath, RouteSchema)
  let (appAst, appErrors) = parseWithErrors(appTokens, appPath)
  result.app = appAst
  result.errors.add(appErrors)
  parsed.incl(appPath)

  # Step 2: Resolve mount directives
  if result.app != nil and result.app.kind == nkApp:
    for mountNode in result.app.appMounts:
      if mountNode.kind == nkMount:
        let mountFile = rootDir / (mountNode.mountPath & ".do")
        if mountFile in parsed:
          continue
        parsed.incl(mountFile)

        if not fileExists(mountFile):
          result.errors.add(ParseError(
            file: mountFile,
            line: mountNode.line,
            col: mountNode.col,
            message: "Mounted file '" & mountNode.mountPath & ".do' not found",
            suggestion: "Create the file '" & mountFile & "' or remove the mount directive"
          ))
          continue

        let featureSource = readFile(mountFile)
        let featureTokens = tokenize(featureSource, mountFile, RouteSchema)
        let (featureAst, featureErrors) = parseWithErrors(featureTokens, mountFile)
        result.featureFiles.add(featureAst)
        result.errors.add(featureErrors)

        # Merge routes from the feature file into the app's routes
        if featureAst != nil and featureAst.kind == nkApp:
          for route in featureAst.appRoutes:
            result.app.appRoutes.add(route)

  # Step 3: Scan views/ directory recursively for .do template files
  let viewsDir = rootDir / "views"
  if dirExists(viewsDir):
    for filepath in walkDirRec(viewsDir):
      if filepath.endsWith(".do"):
        let normalPath = filepath.replace('\\', '/')
        if normalPath in parsed:
          continue
        parsed.incl(normalPath)

        let tmplSource = readFile(filepath)
        let tmplTokens = tokenize(tmplSource, filepath, Template)
        let (tmplAst, tmplErrors) = parseTemplateWithErrors(tmplTokens, filepath)
        result.templates.add(tmplAst)
        result.errors.add(tmplErrors)
