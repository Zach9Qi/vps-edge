# 伪装站：themes/<主题>/ 整个目录就是网站根目录
# 主题由 .env 的 DECOY_THEME 决定（edge 构建时通过 compose.yaml 传进来），换主题：edge theme
FROM nginx:stable-alpine
ARG THEME=forma
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY themes/${THEME}/ /usr/share/nginx/html/
