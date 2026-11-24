# 直接用 nginx 镜像自带的默认配置：监听 80，网站根目录 /usr/share/nginx/html
FROM nginx:stable-alpine
COPY index.html style.css gallery.js /usr/share/nginx/html/
COPY assets/ /usr/share/nginx/html/assets/
