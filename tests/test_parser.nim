import unittest
import std/strutils
import ../src/doot/lexer
import ../src/doot/parser
import ../src/doot/ast

# Helper to tokenize and parse in route/schema mode
proc parseSource(source: string): DootNode =
  let tokens = tokenize(source)
  result = parse(tokens)

proc parseSourceWithErrors(source: string): (DootNode, seq[ParseError]) =
  let tokens = tokenize(source)
  result = parseWithErrors(tokens)

# Helper to tokenize and parse in template mode
proc parseTemplateSource(source: string): DootNode =
  let tokens = tokenize(source, mode = Template)
  result = parseTemplateTokens(tokens)

# ------------------------------------------------------------------
# Config parsing tests
# ------------------------------------------------------------------

suite "Parser - Config":
  test "parse config block with integer directive":
    let source = """config do
  port 3000
end"""
    let ast = parseSource(source)
    check ast.kind == nkApp
    check ast.appConfig != nil
    check ast.appConfig.kind == nkConfig
    check ast.appConfig.configDirectives.len == 1
    check ast.appConfig.configDirectives[0].directiveKey == "port"
    check ast.appConfig.configDirectives[0].directiveValue.kind == nkIntLit
    check ast.appConfig.configDirectives[0].directiveValue.intValue == 3000

  test "parse config block with env() call":
    let source = """config do
  session_secret env("SESSION_SECRET")
end"""
    let ast = parseSource(source)
    check ast.appConfig != nil
    check ast.appConfig.configDirectives.len == 1
    check ast.appConfig.configDirectives[0].directiveKey == "session_secret"
    check ast.appConfig.configDirectives[0].directiveValue.kind == nkEnvCall
    check ast.appConfig.configDirectives[0].directiveValue.envArg == "SESSION_SECRET"

  test "parse config block with multiple directives":
    let source = """config do
  port 3000
  session_secret env("SECRET")
end"""
    let ast = parseSource(source)
    check ast.appConfig != nil
    check ast.appConfig.configDirectives.len == 2
    check ast.appConfig.configDirectives[0].directiveKey == "port"
    check ast.appConfig.configDirectives[1].directiveKey == "session_secret"

# ------------------------------------------------------------------
# Schema parsing tests
# ------------------------------------------------------------------

suite "Parser - Schema":
  test "parse schema with table and fields":
    let source = """schema do
  table "posts" do
    field "title", :string, required: true, max: 200
    field "body", :text, required: true
    field "published", :boolean, default: false
    timestamps
  end
end"""
    let ast = parseSource(source)
    check ast.appSchema != nil
    check ast.appSchema.kind == nkSchema
    check ast.appSchema.schemaTables.len == 1

    let table = ast.appSchema.schemaTables[0]
    check table.kind == nkTable
    check table.tableName == "posts"
    check table.tableFields.len == 3
    check table.hasTimestamps == true

    let titleField = table.tableFields[0]
    check titleField.fieldName == "title"
    check titleField.fieldType == "string"
    check titleField.fieldConstraints.len == 2
    check titleField.fieldConstraints[0].key == "required"
    check titleField.fieldConstraints[0].value.kind == nkBoolLit
    check titleField.fieldConstraints[0].value.boolValue == true
    check titleField.fieldConstraints[1].key == "max"
    check titleField.fieldConstraints[1].value.kind == nkIntLit
    check titleField.fieldConstraints[1].value.intValue == 200

    let bodyField = table.tableFields[1]
    check bodyField.fieldName == "body"
    check bodyField.fieldType == "text"

    let publishedField = table.tableFields[2]
    check publishedField.fieldName == "published"
    check publishedField.fieldType == "boolean"
    check publishedField.fieldConstraints[0].key == "default"
    check publishedField.fieldConstraints[0].value.kind == nkBoolLit
    check publishedField.fieldConstraints[0].value.boolValue == false

  test "parse schema with auth block":
    let source = """schema do
  auth :users do
    roles ["admin", "member"]
    email_verification true
  end
end"""
    let ast = parseSource(source)
    check ast.appSchema != nil
    check ast.appSchema.schemaAuth != nil
    check ast.appSchema.schemaAuth.kind == nkAuth
    check ast.appSchema.schemaAuth.authModel == "users"
    check ast.appSchema.schemaAuth.authRoles == @["admin", "member"]
    check ast.appSchema.schemaAuth.emailVerification == true

  test "parse schema with tables and auth":
    let source = """schema do
  auth :users do
    roles ["admin", "member"]
    email_verification true
  end
  table "posts" do
    field "title", :string
    timestamps
  end
end"""
    let ast = parseSource(source)
    check ast.appSchema != nil
    check ast.appSchema.schemaAuth != nil
    check ast.appSchema.schemaTables.len == 1

# ------------------------------------------------------------------
# Mount parsing tests
# ------------------------------------------------------------------

suite "Parser - Mount":
  test "parse mount directive":
    let source = """mount "posts"
"""
    let ast = parseSource(source)
    check ast.appMounts.len == 1
    check ast.appMounts[0].kind == nkMount
    check ast.appMounts[0].mountPath == "posts"

  test "parse multiple mount directives":
    let source = """mount "posts"
mount "comments"
"""
    let ast = parseSource(source)
    check ast.appMounts.len == 2
    check ast.appMounts[0].mountPath == "posts"
    check ast.appMounts[1].mountPath == "comments"

# ------------------------------------------------------------------
# Route parsing tests
# ------------------------------------------------------------------

suite "Parser - Routes":
  test "parse simple route with GET":
    let source = """route GET "/posts" do |ctx|
  render "posts/index"
end"""
    let ast = parseSource(source)
    check ast.appRoutes.len == 1
    let route = ast.appRoutes[0]
    check route.kind == nkRoute
    check route.httpMethod == "GET"
    check route.routePath == "/posts"
    check route.routeParam == "ctx"
    check route.routeBody.len == 1
    check route.routeBody[0].kind == nkRender
    check route.routeBody[0].renderPath == "posts/index"

  test "parse route with auth option":
    let source = """route GET "/posts/:id", auth: public do |ctx|
  render "posts/show"
end"""
    let ast = parseSource(source)
    let route = ast.appRoutes[0]
    check route.routeAuth == "public"

  test "parse route with POST method":
    let source = """route POST "/posts" do |ctx|
  render "posts/new"
end"""
    let ast = parseSource(source)
    let route = ast.appRoutes[0]
    check route.httpMethod == "POST"
    check route.routePath == "/posts"

  test "parse route with assignment in body":
    let source = """route GET "/posts/:id" do |ctx|
  post = db.posts.find(ctx.params["id"])
  render "posts/show", post: post
end"""
    let ast = parseSource(source)
    let route = ast.appRoutes[0]
    check route.routeBody.len == 2
    check route.routeBody[0].kind == nkAssignment
    check route.routeBody[0].assignName == "post"
    check route.routeBody[1].kind == nkRender
    check route.routeBody[1].renderPath == "posts/show"
    check route.routeBody[1].renderLocals.len == 1
    check route.routeBody[1].renderLocals[0].key == "post"

  test "parse route with redirect":
    let source = """route POST "/posts" do |ctx|
  redirect "/posts"
end"""
    let ast = parseSource(source)
    let route = ast.appRoutes[0]
    check route.routeBody.len == 1
    check route.routeBody[0].kind == nkRedirect

  test "parse route with if/else":
    let source = """route POST "/posts" do |ctx|
  result = db.posts.create(title: ctx.form["title"])
  if result.ok?
    redirect "/posts"
  else
    render "posts/new", errors: result.errors
  end
end"""
    let ast = parseSource(source)
    let route = ast.appRoutes[0]
    check route.routeBody.len == 2
    check route.routeBody[0].kind == nkAssignment
    check route.routeBody[1].kind == nkIf
    let ifNode = route.routeBody[1]
    check ifNode.ifThen.len == 1
    check ifNode.ifThen[0].kind == nkRedirect
    check ifNode.ifElse.len == 1
    check ifNode.ifElse[0].kind == nkRender

  test "parse route with each loop":
    let source = """route GET "/posts" do |ctx|
  posts = db.posts.all()
  each post in posts
    render "posts/card", post: post
  end
end"""
    let ast = parseSource(source)
    let route = ast.appRoutes[0]
    check route.routeBody.len == 2
    check route.routeBody[1].kind == nkEach
    check route.routeBody[1].eachVar == "post"
    check route.routeBody[1].eachBody.len == 1

# ------------------------------------------------------------------
# Group parsing tests
# ------------------------------------------------------------------

suite "Parser - Groups":
  test "parse group with auth option":
    let source = """group auth: required do
  route GET "/posts/new" do |ctx|
    render "posts/new"
  end
end"""
    let ast = parseSource(source)
    check ast.appRoutes.len == 1
    let group = ast.appRoutes[0]
    check group.kind == nkGroup
    check group.groupAuth == "required"
    check group.groupChildren.len == 1
    check group.groupChildren[0].kind == nkRoute

  test "parse group with multiple routes":
    let source = """group auth: required do
  route GET "/posts/new" do |ctx|
    render "posts/new"
  end
  route POST "/posts" do |ctx|
    render "posts/create"
  end
end"""
    let ast = parseSource(source)
    let group = ast.appRoutes[0]
    check group.groupChildren.len == 2
    check group.groupChildren[0].httpMethod == "GET"
    check group.groupChildren[1].httpMethod == "POST"

# ------------------------------------------------------------------
# Native block parsing tests
# ------------------------------------------------------------------

suite "Parser - Native Block":
  test "parse native block":
    let source = "native do\n  proc customHelper(x: int): string =\n    return $x\nend"
    let tokens = tokenize(source)
    let ast = parse(tokens)
    # The native block should be in appRoutes (since it's a top-level construct)
    check ast.appRoutes.len == 1
    check ast.appRoutes[0].kind == nkNativeBlock
    check ast.appRoutes[0].nativeContent.len > 0

  test "parse native block with lexer native mode":
    # When properly tokenized in native mode, content is a single StringLit
    let source = "native do\nend"
    let tokens = tokenize(source)
    let ast = parse(tokens)
    check ast.appRoutes.len == 1
    check ast.appRoutes[0].kind == nkNativeBlock

# ------------------------------------------------------------------
# Expression parsing tests
# ------------------------------------------------------------------

suite "Parser - Expressions":
  test "parse integer literal":
    let tokens = tokenize("route GET \"/\" do |ctx|\n  x = 42\nend")
    let ast = parse(tokens)
    let assign = ast.appRoutes[0].routeBody[0]
    check assign.kind == nkAssignment
    check assign.assignValue.kind == nkIntLit
    check assign.assignValue.intValue == 42

  test "parse string literal":
    let tokens = tokenize("route GET \"/\" do |ctx|\n  x = \"hello\"\nend")
    let ast = parse(tokens)
    let assign = ast.appRoutes[0].routeBody[0]
    check assign.assignValue.kind == nkStringLit
    check assign.assignValue.strValue == "hello"

  test "parse boolean literals":
    let tokens = tokenize("route GET \"/\" do |ctx|\n  x = true\nend")
    let ast = parse(tokens)
    let assign = ast.appRoutes[0].routeBody[0]
    check assign.assignValue.kind == nkBoolLit
    check assign.assignValue.boolValue == true

  test "parse nil literal":
    let tokens = tokenize("route GET \"/\" do |ctx|\n  x = nil\nend")
    let ast = parse(tokens)
    let assign = ast.appRoutes[0].routeBody[0]
    check assign.assignValue.kind == nkNil

  test "parse member access":
    let tokens = tokenize("route GET \"/\" do |ctx|\n  x = ctx.params\nend")
    let ast = parse(tokens)
    let assign = ast.appRoutes[0].routeBody[0]
    check assign.assignValue.kind == nkMemberAccess
    check assign.assignValue.memberObj.kind == nkIdentifier
    check assign.assignValue.memberObj.identName == "ctx"
    check assign.assignValue.memberProp == "params"

  test "parse member access chain":
    let tokens = tokenize("route GET \"/\" do |ctx|\n  x = obj.prop1.prop2\nend")
    let ast = parse(tokens)
    let assign = ast.appRoutes[0].routeBody[0]
    check assign.assignValue.kind == nkMemberAccess
    check assign.assignValue.memberProp == "prop2"
    check assign.assignValue.memberObj.kind == nkMemberAccess
    check assign.assignValue.memberObj.memberProp == "prop1"
    check assign.assignValue.memberObj.memberObj.kind == nkIdentifier
    check assign.assignValue.memberObj.memberObj.identName == "obj"

  test "parse method call":
    let tokens = tokenize("route GET \"/\" do |ctx|\n  x = db.posts.all()\nend")
    let ast = parse(tokens)
    let assign = ast.appRoutes[0].routeBody[0]
    check assign.assignValue.kind == nkMethodCall
    check assign.assignValue.callMethod == "all"
    check assign.assignValue.callArgs.len == 0

  test "parse method call with arguments":
    let tokens = tokenize("route GET \"/\" do |ctx|\n  x = db.posts.find(ctx.params[\"id\"])\nend")
    let ast = parse(tokens)
    let assign = ast.appRoutes[0].routeBody[0]
    check assign.assignValue.kind == nkMethodCall
    check assign.assignValue.callMethod == "find"
    check assign.assignValue.callArgs.len == 1

  test "parse index access":
    let tokens = tokenize("route GET \"/\" do |ctx|\n  x = params[\"id\"]\nend")
    let ast = parse(tokens)
    let assign = ast.appRoutes[0].routeBody[0]
    check assign.assignValue.kind == nkIndexAccess
    check assign.assignValue.indexObj.kind == nkIdentifier
    check assign.assignValue.indexObj.identName == "params"
    check assign.assignValue.indexExpr.kind == nkStringLit

  test "parse array literal":
    let tokens = tokenize("route GET \"/\" do |ctx|\n  x = [1, 2, 3]\nend")
    let ast = parse(tokens)
    let assign = ast.appRoutes[0].routeBody[0]
    check assign.assignValue.kind == nkArrayLit
    check assign.assignValue.arrayElements.len == 3

  test "parse comparison expression":
    let tokens = tokenize("route GET \"/\" do |ctx|\n  x = a == b\nend")
    let ast = parse(tokens)
    let assign = ast.appRoutes[0].routeBody[0]
    check assign.assignValue.kind == nkBinaryOp
    check assign.assignValue.binOp == "=="

  test "parse logical AND":
    let tokens = tokenize("route GET \"/\" do |ctx|\n  x = a && b\nend")
    let ast = parse(tokens)
    let assign = ast.appRoutes[0].routeBody[0]
    check assign.assignValue.kind == nkBinaryOp
    check assign.assignValue.binOp == "&&"

  test "parse logical OR":
    let tokens = tokenize("route GET \"/\" do |ctx|\n  x = a || b\nend")
    let ast = parse(tokens)
    let assign = ast.appRoutes[0].routeBody[0]
    check assign.assignValue.kind == nkBinaryOp
    check assign.assignValue.binOp == "||"

  test "operator precedence: && binds tighter than ||":
    let tokens = tokenize("route GET \"/\" do |ctx|\n  x = a && b || c\nend")
    let ast = parse(tokens)
    let assign = ast.appRoutes[0].routeBody[0]
    # Should be (a && b) || c
    check assign.assignValue.kind == nkBinaryOp
    check assign.assignValue.binOp == "||"
    check assign.assignValue.binLeft.kind == nkBinaryOp
    check assign.assignValue.binLeft.binOp == "&&"
    check assign.assignValue.binRight.kind == nkIdentifier
    check assign.assignValue.binRight.identName == "c"

  test "operator precedence: comparison binds tighter than &&":
    let tokens = tokenize("route GET \"/\" do |ctx|\n  x = a == b && c != d\nend")
    let ast = parse(tokens)
    let assign = ast.appRoutes[0].routeBody[0]
    # Should be (a == b) && (c != d)
    check assign.assignValue.kind == nkBinaryOp
    check assign.assignValue.binOp == "&&"
    check assign.assignValue.binLeft.kind == nkBinaryOp
    check assign.assignValue.binLeft.binOp == "=="
    check assign.assignValue.binRight.kind == nkBinaryOp
    check assign.assignValue.binRight.binOp == "!="

  test "parse unary not":
    let tokens = tokenize("route GET \"/\" do |ctx|\n  x = !flag\nend")
    let ast = parse(tokens)
    let assign = ast.appRoutes[0].routeBody[0]
    check assign.assignValue.kind == nkUnaryOp
    check assign.assignValue.unaryOp == "!"
    check assign.assignValue.unaryOperand.kind == nkIdentifier

  test "parse db.posts.find(ctx.params[\"id\"]) full chain":
    let tokens = tokenize("route GET \"/\" do |ctx|\n  post = db.posts.find(ctx.params[\"id\"])\nend")
    let ast = parse(tokens)
    let assign = ast.appRoutes[0].routeBody[0]
    check assign.kind == nkAssignment
    check assign.assignName == "post"
    let call = assign.assignValue
    check call.kind == nkMethodCall
    check call.callMethod == "find"
    # The object should be db.posts
    check call.callObj.kind == nkMemberAccess
    check call.callObj.memberProp == "posts"
    check call.callObj.memberObj.kind == nkIdentifier
    check call.callObj.memberObj.identName == "db"
    # The argument should be ctx.params["id"]
    check call.callArgs.len == 1
    check call.callArgs[0].kind == nkIndexAccess

  test "parse parenthesized expression":
    let tokens = tokenize("route GET \"/\" do |ctx|\n  x = (a || b) && c\nend")
    let ast = parse(tokens)
    let assign = ast.appRoutes[0].routeBody[0]
    # Should be (a || b) && c
    check assign.assignValue.kind == nkBinaryOp
    check assign.assignValue.binOp == "&&"
    check assign.assignValue.binLeft.kind == nkBinaryOp
    check assign.assignValue.binLeft.binOp == "||"

# ------------------------------------------------------------------
# Template parsing tests
# ------------------------------------------------------------------

suite "Parser - Templates":
  test "parse template with extends":
    let source = "extends \"layouts/base\"\n"
    let ast = parseTemplateSource(source)
    check ast.kind == nkTemplate
    check ast.tmplExtends == "layouts/base"

  test "parse template with block":
    let source = "block title\n  = post.title\n"
    let tokens = tokenize(source, mode = Template)
    let ast = parseTemplateTokens(tokens)
    check ast.kind == nkTemplate
    check ast.tmplBlocks.len >= 1 or ast.tmplBody.len >= 1

  test "parse element with class shorthand":
    let source = "div.card\n"
    let tokens = tokenize(source, mode = Template)
    let ast = parseTemplateTokens(tokens)
    check ast.kind == nkTemplate
    # Should have a body element
    check ast.tmplBody.len >= 1
    let elem = ast.tmplBody[0]
    check elem.kind == nkElement
    check elem.elemTag == "div"
    check elem.elemClasses.len == 1
    check elem.elemClasses[0] == "card"

  test "parse element with multiple classes":
    let source = "div.card.highlighted\n"
    let tokens = tokenize(source, mode = Template)
    let ast = parseTemplateTokens(tokens)
    check ast.tmplBody.len >= 1
    let elem = ast.tmplBody[0]
    check elem.kind == nkElement
    check elem.elemTag == "div"
    check elem.elemClasses.len == 2
    check elem.elemClasses[0] == "card"
    check elem.elemClasses[1] == "highlighted"

  test "parse element with expression output":
    let source = "h1= post.title\n"
    let tokens = tokenize(source, mode = Template)
    let ast = parseTemplateTokens(tokens)
    check ast.tmplBody.len >= 1
    let elem = ast.tmplBody[0]
    check elem.kind == nkElement
    check elem.elemTag == "h1"
    check elem.elemExprOutput != nil

  test "parse template if block":
    let source = "if ctx.current_user\n  div.actions\n"
    let tokens = tokenize(source, mode = Template)
    let ast = parseTemplateTokens(tokens)
    check ast.tmplBody.len >= 1
    let ifNode = ast.tmplBody[0]
    check ifNode.kind == nkTemplateIf
    check ifNode.tmplIfThen.len >= 1

  test "parse template each block":
    let source = "each comment in comments\n  div.comment\n"
    let tokens = tokenize(source, mode = Template)
    let ast = parseTemplateTokens(tokens)
    check ast.tmplBody.len >= 1
    let eachNode = ast.tmplBody[0]
    check eachNode.kind == nkTemplateEach
    check eachNode.tmplEachVar == "comment"
    check eachNode.tmplEachBody.len >= 1

  test "parse partial":
    let source = "partial \"comments/form\", post: post\n"
    let tokens = tokenize(source, mode = Template)
    let ast = parseTemplateTokens(tokens)
    check ast.tmplBody.len >= 1
    let partial = ast.tmplBody[0]
    check partial.kind == nkPartial
    check partial.partialPath == "comments/form"
    check partial.partialLocals.len == 1
    check partial.partialLocals[0].key == "post"

# ------------------------------------------------------------------
# Error reporting tests
# ------------------------------------------------------------------

suite "Parser - Error Reporting":
  test "missing end keyword reports error with location":
    let source = """config do
  port 3000
"""
    let (_, errors) = parseSourceWithErrors(source)
    check errors.len >= 1
    # Should mention expecting 'end'
    check "Expected tkEnd" in errors[0].message or "Expected" in errors[0].message
    check errors[0].line > 0

  test "misspelled keyword produces suggestion":
    let source = "roote GET \"/posts\" do |ctx|\n  render \"posts/index\"\nend\n"
    let (_, errors) = parseSourceWithErrors(source)
    check errors.len >= 1
    # Should suggest 'route'
    var hasSuggestion = false
    for err in errors:
      if err.suggestion.contains("route"):
        hasSuggestion = true
        break
    check hasSuggestion

  test "multiple errors reported in single pass":
    let source = """roote GET "/x" do |ctx|
  render "a"
end
routee POST "/y" do |ctx|
  render "b"
end
"""
    let (_, errors) = parseSourceWithErrors(source)
    check errors.len >= 2

  test "error includes file and column info":
    let tokens = tokenize("config do\n  port 3000", "app.do")
    let (_, errors) = parseWithErrors(tokens, "app.do")
    check errors.len >= 1
    check errors[0].file == "app.do" or errors[0].file == "<input>"

  test "unknown type annotation produces helpful error":
    let source = """schema do
  table "users" do
    field "name", :unknown_type
  end
end"""
    let (_, errors) = parseSourceWithErrors(source)
    # The lexer will produce tkColon + tkIdentifier for :unknown_type
    # The parser should report an error about expected type
    check errors.len >= 1

# ------------------------------------------------------------------
# Complete application parsing tests
# ------------------------------------------------------------------

suite "Parser - Complete App":
  test "parse app with config, schema, mount, and route":
    let source = """config do
  port 3000
end

schema do
  table "posts" do
    field "title", :string, required: true
    timestamps
  end
end

mount "posts"

route GET "/posts" do |ctx|
  posts = db.posts.all()
  render "posts/index", posts: posts
end
"""
    let ast = parseSource(source)
    check ast.kind == nkApp
    check ast.appConfig != nil
    check ast.appSchema != nil
    check ast.appMounts.len == 1
    check ast.appRoutes.len == 1

  test "parse app with group containing multiple routes":
    let source = """group auth: required do
  route GET "/posts/new" do |ctx|
    render "posts/new"
  end
  route POST "/posts" do |ctx|
    result = db.posts.create(title: ctx.form["title"], body: ctx.form["body"])
    if result.ok?
      redirect "/posts"
    else
      render "posts/new", errors: result.errors
    end
  end
end
"""
    let ast = parseSource(source)
    check ast.appRoutes.len == 1
    let group = ast.appRoutes[0]
    check group.kind == nkGroup
    check group.groupAuth == "required"
    check group.groupChildren.len == 2

    # Second route has if/else
    let postRoute = group.groupChildren[1]
    check postRoute.routeBody.len == 2
    check postRoute.routeBody[0].kind == nkAssignment
    check postRoute.routeBody[1].kind == nkIf

# ------------------------------------------------------------------
# Edge cases
# ------------------------------------------------------------------

suite "Parser - Edge Cases":
  test "empty source produces valid app node":
    let ast = parseSource("")
    check ast.kind == nkApp
    check ast.appConfig == nil
    check ast.appSchema == nil
    check ast.appMounts.len == 0
    check ast.appRoutes.len == 0

  test "source with only newlines produces valid app node":
    let ast = parseSource("\n\n\n")
    check ast.kind == nkApp

  test "route without ctx parameter":
    let source = """route GET "/health" do
  render "health"
end"""
    let ast = parseSource(source)
    let route = ast.appRoutes[0]
    check route.routeParam == ""
    check route.routeBody.len == 1

  test "method call with keyword arguments":
    let tokens = tokenize("route GET \"/\" do |ctx|\n  x = db.posts.create(title: ctx.form[\"title\"])\nend")
    let ast = parse(tokens)
    let assign = ast.appRoutes[0].routeBody[0]
    let call = assign.assignValue
    check call.kind == nkMethodCall
    check call.callMethod == "create"
    check call.callArgs.len == 1

# ------------------------------------------------------------------
# Template #id shorthand tests
# ------------------------------------------------------------------

suite "Parser - Template #id Shorthand":
  test "parse element with #id shorthand":
    let source = "div#main\n"
    let tokens = tokenize(source, mode = Template)
    let ast = parseTemplateTokens(tokens)
    check ast.tmplBody.len >= 1
    let elem = ast.tmplBody[0]
    check elem.kind == nkElement
    check elem.elemTag == "div"
    check elem.elemId == "main"

  test "parse element with combined class and id":
    let source = "div#sidebar.panel\n"
    let tokens = tokenize(source, mode = Template)
    let ast = parseTemplateTokens(tokens)
    check ast.tmplBody.len >= 1
    let elem = ast.tmplBody[0]
    check elem.kind == nkElement
    check elem.elemTag == "div"
    check elem.elemId == "sidebar"
    check elem.elemClasses.len == 1
    check elem.elemClasses[0] == "panel"

  test "parse element with class then id":
    let source = "div.panel#sidebar\n"
    let tokens = tokenize(source, mode = Template)
    let ast = parseTemplateTokens(tokens)
    check ast.tmplBody.len >= 1
    let elem = ast.tmplBody[0]
    check elem.kind == nkElement
    check elem.elemTag == "div"
    check elem.elemId == "sidebar"
    check elem.elemClasses.len == 1
    check elem.elemClasses[0] == "panel"

  test "parse element with multiple classes and id":
    let source = "div.card.dark#content\n"
    let tokens = tokenize(source, mode = Template)
    let ast = parseTemplateTokens(tokens)
    check ast.tmplBody.len >= 1
    let elem = ast.tmplBody[0]
    check elem.kind == nkElement
    check elem.elemTag == "div"
    check elem.elemId == "content"
    check elem.elemClasses.len == 2
    check elem.elemClasses[0] == "card"
    check elem.elemClasses[1] == "dark"

# ------------------------------------------------------------------
# Multi-line method call arguments tests
# ------------------------------------------------------------------

suite "Parser - Multi-line Method Calls":
  test "parse method call with arguments on multiple lines":
    let source = "route GET \"/\" do |ctx|\n  x = db.posts.create(\n    title: ctx.form[\"title\"],\n    body: ctx.form[\"body\"]\n  )\nend"
    let tokens = tokenize(source)
    let ast = parse(tokens)
    let assign = ast.appRoutes[0].routeBody[0]
    let call = assign.assignValue
    check call.kind == nkMethodCall
    check call.callMethod == "create"
    check call.callArgs.len == 2
    check call.callArgs[0].kind == nkAssignment
    check call.callArgs[0].assignName == "title"
    check call.callArgs[1].kind == nkAssignment
    check call.callArgs[1].assignName == "body"

  test "parse method call with newline after opening paren":
    let source = "route GET \"/\" do |ctx|\n  x = db.posts.all(\n  )\nend"
    let tokens = tokenize(source)
    let ast = parse(tokens)
    let assign = ast.appRoutes[0].routeBody[0]
    let call = assign.assignValue
    check call.kind == nkMethodCall
    check call.callMethod == "all"
    check call.callArgs.len == 0

  test "parse method call with single arg on next line":
    let source = "route GET \"/\" do |ctx|\n  x = db.posts.find(\n    ctx.params[\"id\"]\n  )\nend"
    let tokens = tokenize(source)
    let ast = parse(tokens)
    let assign = ast.appRoutes[0].routeBody[0]
    let call = assign.assignValue
    check call.kind == nkMethodCall
    check call.callMethod == "find"
    check call.callArgs.len == 1

# ------------------------------------------------------------------
# Route role option with string literal tests
# ------------------------------------------------------------------

suite "Parser - Route Role String Literal":
  test "parse route with role as string literal":
    let source = "route GET \"/admin\", role: \"admin\" do |ctx|\n  render \"admin/index\"\nend"
    let ast = parseSource(source)
    let route = ast.appRoutes[0]
    check route.routeRole == "admin"

  test "parse route with role as identifier":
    let source = "route GET \"/admin\", role: admin do |ctx|\n  render \"admin/index\"\nend"
    let ast = parseSource(source)
    let route = ast.appRoutes[0]
    check route.routeRole == "admin"

  test "parse group with role as string literal":
    let source = "group auth: required, role: \"moderator\" do\n  route GET \"/mod\" do |ctx|\n    render \"mod/index\"\n  end\nend"
    let ast = parseSource(source)
    let group = ast.appRoutes[0]
    check group.kind == nkGroup
    check group.groupRole == "moderator"

  test "parse route with auth and role as string literal":
    let source = "route GET \"/admin\", auth: required, role: \"admin\" do |ctx|\n  render \"admin/index\"\nend"
    let ast = parseSource(source)
    let route = ast.appRoutes[0]
    check route.routeAuth == "required"
    check route.routeRole == "admin"
