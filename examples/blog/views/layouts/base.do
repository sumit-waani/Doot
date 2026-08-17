doctype html
html
  head
    title "My Blog"
    meta charset="utf-8"
    meta name="viewport" content="width=device-width, initial-scale=1"
    block head
  body
    nav.main-nav
      div.container
        a.logo href="/" "My Blog"
        div.nav-links
          a href="/posts" "Posts"
          if ctx.current_user
            a href="/posts/new" "New Post"
            a href="/logout" "Logout"
          else
            a href="/login" "Login"
            a href="/signup" "Sign Up"
    main.container
      block content
    footer.site-footer
      div.container
        p "Built with Doot"
