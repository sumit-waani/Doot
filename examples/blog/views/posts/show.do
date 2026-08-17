extends "layouts/base"

block title
  = post.title

block content
  article.post
    header.post-header
      h1.post-title= post.title
      div.post-meta
        span= post.created_at
    div.post-body!= post.body
    if ctx.current_user
      div.post-actions
        a href="/posts/#{post.id}/edit" "Edit"
  section.comments
    h2 "Comments"
    if comments.empty?
      p "No comments yet."
    else
      each comment in comments
        div.comment
          p.comment-body= comment.body
    partial "comments/form", post: post
