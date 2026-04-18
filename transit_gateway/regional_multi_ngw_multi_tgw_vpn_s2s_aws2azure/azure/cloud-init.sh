#!/bin/bash
set -eux
apt-get update -y
apt-get install -y nginx
cat > /etc/nginx/sites-available/default <<'NGINX'
server {
    listen 80 default_server;
    location / {
        return 200 "remote_addr=$remote_addr\nhost=$hostname\n";
        add_header Content-Type text/plain;
    }
    location /whoami {
        return 200 "remote_addr=$remote_addr\nhost=$hostname\n";
        add_header Content-Type text/plain;
    }
}
NGINX
systemctl restart nginx
systemctl enable nginx
