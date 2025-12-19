# Тестовое приложение на nginx для демонстрации работы cloud platform.

## Сборка и запуск

### Сборка образа
```
docker build -t diploma-app:1.0.0 .
```
### Запуск контейнера
```
docker run -p 8080:80 diploma-app:1.0.0
```

###  Доступ
Приложение доступно по [http://localhost:8080](http://localhost:8080)
