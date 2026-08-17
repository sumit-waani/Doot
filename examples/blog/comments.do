# Comments feature file

group auth: required do
  route POST "/posts/:post_id/comments" do |ctx|
    result = db.comments.create(body: ctx.form["body"], post_id: ctx.params["post_id"], user_id: ctx.current_user.id)
    if result.ok?
      redirect "/posts/#{ctx.params["post_id"]}"
    else
      redirect "/posts/#{ctx.params["post_id"]}"
    end
  end
end
