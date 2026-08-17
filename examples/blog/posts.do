# Posts feature file

group auth: required do
  route GET "/posts/new" do |ctx|
    render "posts/new"
  end

  route POST "/posts" do |ctx|
    result = db.posts.create(title: ctx.form["title"], body: ctx.form["body"], slug: ctx.form["title"], user_id: ctx.current_user.id)
    if result.ok?
      redirect "/posts/#{result.post.slug}"
    else
      render "posts/new", errors: result.errors
    end
  end

  route PUT "/posts/:id" do |ctx|
    post = db.posts.find(ctx.params["id"])
    result = db.posts.update(post, title: ctx.form["title"], body: ctx.form["body"])
    if result.ok?
      redirect "/posts/#{post.id}"
    else
      render "posts/edit", post: post, errors: result.errors
    end
  end

  route DELETE "/posts/:id" do |ctx|
    post = db.posts.find(ctx.params["id"])
    db.posts.delete(post)
    redirect "/posts"
  end
end

route GET "/posts", auth: public do |ctx|
  posts = db.posts.all(where: "published = true", order: "created_at desc")
  render "posts/index", posts: posts
end

route GET "/posts/:slug", auth: public do |ctx|
  post = db.posts.find_by(slug: ctx.params["slug"])
  comments = db.comments.all(where: "post_id = #{post.id}", order: "created_at asc")
  render "posts/show", post: post, comments: comments
end
