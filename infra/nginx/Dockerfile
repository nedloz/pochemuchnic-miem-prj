FROM node:20-alpine AS frontend-build
WORKDIR /app/frontend

# В проекте используется pnpm: в репозитории лежит только pnpm-lock.yaml, package-lock.json
# нет. Прежняя версия делала `npm install`, который этот lock-файл игнорирует и разрешает
# зависимости заново — сборка переставала быть воспроизводимой.
# Версия pnpm выбрана по lockfileVersion: '9.0' (её пишут pnpm 9 и 10).
RUN npm install -g pnpm@10

COPY frontend/package.json frontend/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

COPY frontend/ ./
RUN pnpm run build

FROM nginx:1.27-alpine
COPY infra/nginx/nginx.conf /etc/nginx/nginx.conf
COPY --from=frontend-build /app/frontend/dist /usr/share/nginx/html
