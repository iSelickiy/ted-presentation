FROM nginx:1.27-alpine

COPY nginx.conf /etc/nginx/nginx.conf
COPY index.html /usr/share/nginx/html/index.html
COPY assets/ /usr/share/nginx/html/assets/
COPY materials/ /usr/share/nginx/html/materials/
COPY routine-agent-guide/ /usr/share/nginx/html/routine-agent-guide/
COPY vpn-agent-guide/ /usr/share/nginx/html/vpn-agent-guide/

EXPOSE 80
