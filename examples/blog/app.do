# Blog Application - Main Configuration

config do
  port 3000
  session_secret env("SESSION_SECRET")
end

schema do
  auth :users do
    roles ["admin", "editor", "member"]
    email_verification true
  end

  table "posts" do
    field "title", :string, required: true, max: 200
    field "body", :text, required: true
    field "slug", :string, required: true
    field "published", :boolean, default: false
    field "user_id", :integer, required: true
    timestamps
  end

  table "comments" do
    field "body", :text, required: true, max: 1000
    field "post_id", :integer, required: true
    field "user_id", :integer, required: true
    timestamps
  end
end

mount "posts"
mount "comments"
