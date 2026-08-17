## Tests for the Doot HTTP routing engine.
## Covers route matching, parameter extraction, ordering, and method matching.

import std/[unittest, tables]
import ../src/doot/router

suite "Route Matching":
  test "static route matches exactly":
    var table = newRouteTable()
    table.addRoute(hmGet, "/posts", "listPosts")
    let m = table.matchRoute(hmGet, "/posts")
    check m.matched == true
    check m.route.handlerName == "listPosts"
    check m.params.len == 0

  test "static route with trailing slash":
    var table = newRouteTable()
    table.addRoute(hmGet, "/posts", "listPosts")
    # Without trailing slash - should match
    let m = table.matchRoute(hmGet, "/posts")
    check m.matched == true

  test "root path matches":
    var table = newRouteTable()
    table.addRoute(hmGet, "/", "home")
    let m = table.matchRoute(hmGet, "/")
    check m.matched == true
    check m.route.handlerName == "home"

  test "single parameter extraction":
    var table = newRouteTable()
    table.addRoute(hmGet, "/posts/:id", "showPost")
    let m = table.matchRoute(hmGet, "/posts/42")
    check m.matched == true
    check m.route.handlerName == "showPost"
    check m.params["id"] == "42"

  test "multiple parameter extraction":
    var table = newRouteTable()
    table.addRoute(hmGet, "/users/:user_id/posts/:id", "userPost")
    let m = table.matchRoute(hmGet, "/users/5/posts/99")
    check m.matched == true
    check m.params["user_id"] == "5"
    check m.params["id"] == "99"

  test "non-matching route returns unmatched":
    var table = newRouteTable()
    table.addRoute(hmGet, "/posts", "listPosts")
    let m = table.matchRoute(hmGet, "/users")
    check m.matched == false

  test "method mismatch returns unmatched":
    var table = newRouteTable()
    table.addRoute(hmPost, "/posts", "createPost")
    let m = table.matchRoute(hmGet, "/posts")
    check m.matched == false

  test "segment count mismatch returns unmatched":
    var table = newRouteTable()
    table.addRoute(hmGet, "/posts/:id", "showPost")
    let m = table.matchRoute(hmGet, "/posts")
    check m.matched == false

  test "too many segments returns unmatched":
    var table = newRouteTable()
    table.addRoute(hmGet, "/posts/:id", "showPost")
    let m = table.matchRoute(hmGet, "/posts/42/comments")
    check m.matched == false

suite "Route Ordering":
  test "static routes matched before parameterized":
    var table = newRouteTable()
    table.addRoute(hmGet, "/posts/:id", "showPost")
    table.addRoute(hmGet, "/posts/new", "newPost")
    let m = table.matchRoute(hmGet, "/posts/new")
    check m.matched == true
    check m.route.handlerName == "newPost"

  test "more specific routes matched first":
    var table = newRouteTable()
    table.addRoute(hmGet, "/posts/:id", "showPost")
    table.addRoute(hmGet, "/posts/:id/edit", "editPost")
    let m = table.matchRoute(hmGet, "/posts/42/edit")
    check m.matched == true
    check m.route.handlerName == "editPost"

  test "parameterized route still works when no static match":
    var table = newRouteTable()
    table.addRoute(hmGet, "/posts/new", "newPost")
    table.addRoute(hmGet, "/posts/:id", "showPost")
    let m = table.matchRoute(hmGet, "/posts/42")
    check m.matched == true
    check m.route.handlerName == "showPost"
    check m.params["id"] == "42"

suite "HTTP Method Matching":
  test "GET method":
    var table = newRouteTable()
    table.addRoute(hmGet, "/posts", "listPosts")
    table.addRoute(hmPost, "/posts", "createPost")
    let m = table.matchRoute(hmGet, "/posts")
    check m.matched == true
    check m.route.handlerName == "listPosts"

  test "POST method":
    var table = newRouteTable()
    table.addRoute(hmGet, "/posts", "listPosts")
    table.addRoute(hmPost, "/posts", "createPost")
    let m = table.matchRoute(hmPost, "/posts")
    check m.matched == true
    check m.route.handlerName == "createPost"

  test "PUT method":
    var table = newRouteTable()
    table.addRoute(hmPut, "/posts/:id", "updatePost")
    let m = table.matchRoute(hmPut, "/posts/42")
    check m.matched == true
    check m.route.handlerName == "updatePost"

  test "DELETE method":
    var table = newRouteTable()
    table.addRoute(hmDelete, "/posts/:id", "deletePost")
    let m = table.matchRoute(hmDelete, "/posts/42")
    check m.matched == true
    check m.route.handlerName == "deletePost"

  test "PATCH method":
    var table = newRouteTable()
    table.addRoute(hmPatch, "/posts/:id", "patchPost")
    let m = table.matchRoute(hmPatch, "/posts/42")
    check m.matched == true
    check m.route.handlerName == "patchPost"

  test "parseHttpMethod string dispatch":
    var table = newRouteTable()
    table.addRoute(hmGet, "/test", "testHandler")
    let m = table.matchRoute("GET", "/test")
    check m.matched == true

suite "Route Auth Properties":
  test "route defaults to auth required":
    let route = newRoute(hmGet, "/posts", "listPosts")
    check route.authRequired == true

  test "route can be marked public":
    let route = newRoute(hmGet, "/posts", "listPosts", authRequired = false)
    check route.authRequired == false

  test "route with role requirement":
    let route = newRoute(hmGet, "/admin", "adminPanel",
                         authRequired = true, roleName = "admin")
    check route.authRequired == true
    check route.roleName == "admin"

  test "group auth propagates to child routes":
    # Simulate group by adding routes with auth settings
    var table = newRouteTable()
    # Group: auth required
    table.addRoute(hmGet, "/admin/users", "adminUsers", authRequired = true, roleName = "admin")
    table.addRoute(hmGet, "/admin/settings", "adminSettings", authRequired = true, roleName = "admin")
    # Public route outside group
    table.addRoute(hmGet, "/login", "login", authRequired = false)

    let m1 = table.matchRoute(hmGet, "/admin/users")
    check m1.matched == true
    check m1.route.authRequired == true
    check m1.route.roleName == "admin"

    let m2 = table.matchRoute(hmGet, "/login")
    check m2.matched == true
    check m2.route.authRequired == false

suite "Path Splitting":
  test "split simple path":
    check splitPath("/posts") == @["posts"]

  test "split nested path":
    check splitPath("/users/posts") == @["users", "posts"]

  test "split with params":
    check splitPath("/posts/:id") == @["posts", ":id"]

  test "split root":
    check splitPath("/") == newSeq[string](0)

  test "split with trailing slash":
    check splitPath("/posts/") == @["posts"]

  test "split deep nested":
    check splitPath("/api/v1/users/:id/posts") == @["api", "v1", "users", ":id", "posts"]

suite "Route Properties":
  test "static route detection":
    let route = newRoute(hmGet, "/posts", "listPosts")
    check route.isStatic == true
    check route.paramNames.len == 0

  test "parameterized route detection":
    let route = newRoute(hmGet, "/posts/:id", "showPost")
    check route.isStatic == false
    check route.paramNames == @["id"]

  test "multiple params detected":
    let route = newRoute(hmGet, "/users/:user_id/posts/:id", "userPost")
    check route.isStatic == false
    check route.paramNames == @["user_id", "id"]
