FROM nginx:alpine

# Создаём папку для конфигов
RUN mkdir -p /etc/nginx/conf.d/

# Копируем свой кастомный конфиг
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Копируем HTML и другие файлы в корень Nginx
COPY . /usr/share/nginx/html

EXPOSE 80
