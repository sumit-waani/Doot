extends "layouts/base"

block title
  "All Posts"

block content
  h1 "All Posts"
  if posts.empty?
    p.no-posts "No posts yet. Be the first to write one!"
  else
    each post in posts
      div.post-card
        h2.post-title
          a href="/posts/#{post.slug}" = post.title
        p.post-excerpt= post.body
        div.post-meta
          span= post.user_id
          span= post.created_at
