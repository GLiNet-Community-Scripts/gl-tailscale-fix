-- gl-tailscale-fix: clear content-length for injected HTML
-- Copyright (c) 2026 RemoteToHome Consulting (https://remotetohome.io)
-- https://github.com/RemoteToHome-io/gl-tailscale-fix
if ngx.var.uri == "/gl_home.html" or ngx.var.uri == "/" then
    ngx.header.content_length = nil
end
