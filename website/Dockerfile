# SPDX-License-Identifier: MIT
FROM ghcr.io/nginx/nginx-unprivileged:stable-alpine@sha256:c3fc8fa482be50ef709c6438eb1bc98d50dbfe5a9b48be90711b8814f4dfd701

COPY deploy/nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html styles.css app.js demos.js theme.js /usr/share/nginx/html/
COPY assets/ /usr/share/nginx/html/assets/
COPY privacy/ /usr/share/nginx/html/privacy/

USER 101:101
EXPOSE 8080
ENTRYPOINT ["nginx"]
CMD ["-g", "daemon off;"]
