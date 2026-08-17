import unittest
import std/os
import std/strutils
import ../src/doot/resolver
import ../src/doot/ast
import ../src/doot/lexer
import ../src/doot/parser

# ------------------------------------------------------------------
# Multi-file resolver integration tests
# ------------------------------------------------------------------

suite "Integration - parseProject Blog Example":
  test "parseProject parses blog example with no errors":
    let project = parseProject("examples/blog")
    check project.errors.len == 0

  test "app.do produces a valid nkApp node":
    let project = parseProject("examples/blog")
    check project.app != nil
    check project.app.kind == nkApp

  test "config block parsed with port and session_secret":
    let project = parseProject("examples/blog")
    check project.app.appConfig != nil
    check project.app.appConfig.kind == nkConfig
    check project.app.appConfig.configDirectives.len == 2
    let portDirective = project.app.appConfig.configDirectives[0]
    check portDirective.directiveKey == "port"
    check portDirective.directiveValue.kind == nkIntLit
    check portDirective.directiveValue.intValue == 3000
    let secretDirective = project.app.appConfig.configDirectives[1]
    check secretDirective.directiveKey == "session_secret"
    check secretDirective.directiveValue.kind == nkEnvCall
    check secretDirective.directiveValue.envArg == "SESSION_SECRET"

  test "schema block parsed with auth and 2 tables":
    let project = parseProject("examples/blog")
    check project.app.appSchema != nil
    check project.app.appSchema.kind == nkSchema
    check project.app.appSchema.schemaTables.len == 2
    check project.app.appSchema.schemaAuth != nil
    check project.app.appSchema.schemaAuth.kind == nkAuth
    check project.app.appSchema.schemaAuth.authModel == "users"
    check project.app.appSchema.schemaAuth.authRoles == @["admin", "editor", "member"]
    check project.app.appSchema.schemaAuth.emailVerification == true

  test "posts table has correct fields and timestamps":
    let project = parseProject("examples/blog")
    let postsTable = project.app.appSchema.schemaTables[0]
    check postsTable.kind == nkTable
    check postsTable.tableName == "posts"
    check postsTable.tableFields.len == 5
    check postsTable.hasTimestamps == true
    # Verify first field
    let titleField = postsTable.tableFields[0]
    check titleField.fieldName == "title"
    check titleField.fieldType == "string"
    check titleField.fieldConstraints.len == 2
    check titleField.fieldConstraints[0].key == "required"
    check titleField.fieldConstraints[1].key == "max"

  test "comments table has correct fields and timestamps":
    let project = parseProject("examples/blog")
    let commentsTable = project.app.appSchema.schemaTables[1]
    check commentsTable.kind == nkTable
    check commentsTable.tableName == "comments"
    check commentsTable.tableFields.len == 3
    check commentsTable.hasTimestamps == true

  test "mount directives resolved correctly":
    let project = parseProject("examples/blog")
    check project.app.appMounts.len == 2
    check project.app.appMounts[0].mountPath == "posts"
    check project.app.appMounts[1].mountPath == "comments"

  test "feature files parsed from mount directives":
    let project = parseProject("examples/blog")
    check project.featureFiles.len == 2

  test "routes from posts.do merged into app routes":
    let project = parseProject("examples/blog")
    # posts.do has: 1 group (with 4 routes) + 2 public routes = 3 top-level
    # comments.do has: 1 group = 1 top-level
    # Total merged: 3 + 1 = 4 top-level route/group nodes
    check project.app.appRoutes.len == 4

  test "posts.do group has auth: required":
    let project = parseProject("examples/blog")
    # First route should be the group from posts.do
    let postsGroup = project.app.appRoutes[0]
    check postsGroup.kind == nkGroup
    check postsGroup.groupAuth == "required"
    check postsGroup.groupChildren.len == 4

  test "posts.do group contains correct routes":
    let project = parseProject("examples/blog")
    let postsGroup = project.app.appRoutes[0]
    check postsGroup.groupChildren[0].httpMethod == "GET"
    check postsGroup.groupChildren[0].routePath == "/posts/new"
    check postsGroup.groupChildren[1].httpMethod == "POST"
    check postsGroup.groupChildren[1].routePath == "/posts"
    check postsGroup.groupChildren[2].httpMethod == "PUT"
    check postsGroup.groupChildren[2].routePath == "/posts/:id"
    check postsGroup.groupChildren[3].httpMethod == "DELETE"
    check postsGroup.groupChildren[3].routePath == "/posts/:id"

  test "public routes from posts.do have auth: public":
    let project = parseProject("examples/blog")
    let getAll = project.app.appRoutes[1]
    check getAll.kind == nkRoute
    check getAll.httpMethod == "GET"
    check getAll.routePath == "/posts"
    check getAll.routeAuth == "public"
    let getSlug = project.app.appRoutes[2]
    check getSlug.kind == nkRoute
    check getSlug.httpMethod == "GET"
    check getSlug.routePath == "/posts/:slug"
    check getSlug.routeAuth == "public"

  test "comments.do group parsed correctly":
    let project = parseProject("examples/blog")
    let commentsGroup = project.app.appRoutes[3]
    check commentsGroup.kind == nkGroup
    check commentsGroup.groupAuth == "required"
    check commentsGroup.groupChildren.len == 1
    check commentsGroup.groupChildren[0].httpMethod == "POST"
    check commentsGroup.groupChildren[0].routePath == "/posts/:post_id/comments"

  test "route handlers contain if/else and render/redirect":
    let project = parseProject("examples/blog")
    let postsGroup = project.app.appRoutes[0]
    let postRoute = postsGroup.groupChildren[1]  # POST /posts
    check postRoute.routeParam == "ctx"
    check postRoute.routeBody.len >= 2  # assignment + if block

  test "templates parsed from views/ directory":
    let project = parseProject("examples/blog")
    check project.templates.len == 4  # base.do, index.do, show.do, _form.do

  test "templates are nkTemplate nodes":
    let project = parseProject("examples/blog")
    for tmpl in project.templates:
      check tmpl.kind == nkTemplate

  test "index.do template extends layouts/base":
    let project = parseProject("examples/blog")
    var found = false
    for tmpl in project.templates:
      if tmpl.tmplExtends == "layouts/base":
        # Found either index.do or show.do
        found = true
        break
    check found == true

  test "base.do template has no extends and has body elements":
    let project = parseProject("examples/blog")
    var found = false
    for tmpl in project.templates:
      if tmpl.tmplExtends == "" and tmpl.tmplBody.len > 0:
        found = true
        break
    check found == true

  test "templates with extends have block definitions":
    let project = parseProject("examples/blog")
    var hasBlocks = false
    for tmpl in project.templates:
      if tmpl.tmplExtends != "" and tmpl.tmplBlocks.len > 0:
        hasBlocks = true
        break
    check hasBlocks == true

  test "show.do template has partial reference":
    let project = parseProject("examples/blog")
    var hasPartial = false
    for tmpl in project.templates:
      if tmpl.tmplExtends == "layouts/base":
        for blk in tmpl.tmplBlocks:
          for child in blk.blockContent:
            if child.kind == nkPartial:
              hasPartial = true
              break
            # Check nested children in elements
            if child.kind == nkElement:
              for sub in child.elemChildren:
                if sub.kind == nkPartial:
                  hasPartial = true
                  break
    check hasPartial == true

suite "Integration - Error Reporting":
  test "misspelled keyword produces error with suggestion":
    let source = """routee GET "/test" do |ctx|
  render "test"
end"""
    let tokens = tokenize(source, "<test>", RouteSchema)
    let (_, errors) = parseWithErrors(tokens, "<test>")
    check errors.len > 0
    var hasSuggestion = false
    for err in errors:
      if err.suggestion.contains("route"):
        hasSuggestion = true
        break
    check hasSuggestion == true

  test "tab in template mode produces error":
    let source = "div\n\tchild"
    let (_, lexErrors) = tokenizeWithErrors(source, "<test>", Template)
    check lexErrors.len > 0
    var hasTabError = false
    for err in lexErrors:
      if err.contains("tab") or err.contains("Tab"):
        hasTabError = true
        break
    check hasTabError == true

  test "multiple errors reported in a single pass":
    let source = """routee GET "/a" do |ctx|
  render "a"
end
schemaa do
end"""
    let tokens = tokenize(source, "<multi-error>", RouteSchema)
    let (_, errors) = parseWithErrors(tokens, "<multi-error>")
    check errors.len >= 2

  test "errors include correct file and line info":
    let source = """config do
  port 3000
end
routee GET "/test" do |ctx|
  render "test"
end"""
    let tokens = tokenize(source, "test_file.do", RouteSchema)
    let (_, errors) = parseWithErrors(tokens, "test_file.do")
    check errors.len > 0
    check errors[0].file == "test_file.do"
    check errors[0].line >= 4  # error is on the "routee" line

  test "missing mounted file produces error with suggestion":
    # Create a temporary app.do that mounts a non-existent file
    let tmpDir = getTempDir() / "doot_test_missing_mount"
    createDir(tmpDir)
    writeFile(tmpDir / "app.do", """config do
  port 8080
end
mount "nonexistent"
""")
    let project = parseProject(tmpDir)
    check project.errors.len >= 1
    var hasMountError = false
    for err in project.errors:
      if err.message.contains("not found"):
        hasMountError = true
        check err.suggestion.len > 0
        break
    check hasMountError == true
    # Cleanup
    removeDir(tmpDir)

  test "missing app.do produces error with suggestion":
    let tmpDir = getTempDir() / "doot_test_no_app"
    createDir(tmpDir)
    let project = parseProject(tmpDir)
    check project.errors.len >= 1
    check project.errors[0].message.contains("app.do")
    check project.errors[0].suggestion.len > 0
    # Cleanup
    removeDir(tmpDir)

suite "Integration - Project Structure":
  test "project with only app.do parses successfully":
    let tmpDir = getTempDir() / "doot_test_app_only"
    createDir(tmpDir)
    writeFile(tmpDir / "app.do", """config do
  port 4000
end

schema do
  table "items" do
    field "name", :string, required: true
    timestamps
  end
end
""")
    let project = parseProject(tmpDir)
    check project.errors.len == 0
    check project.app.appConfig != nil
    check project.app.appSchema != nil
    check project.app.appSchema.schemaTables.len == 1
    check project.featureFiles.len == 0
    check project.templates.len == 0
    # Cleanup
    removeDir(tmpDir)

  test "project with views but no mounts works":
    let tmpDir = getTempDir() / "doot_test_views_only"
    createDir(tmpDir)
    createDir(tmpDir / "views")
    writeFile(tmpDir / "app.do", """config do
  port 5000
end
""")
    writeFile(tmpDir / "views" / "home.do", """h1 "Welcome"
p "Hello World"
""")
    let project = parseProject(tmpDir)
    check project.errors.len == 0
    check project.templates.len == 1
    check project.templates[0].kind == nkTemplate
    # Cleanup
    removeDir(tmpDir)
