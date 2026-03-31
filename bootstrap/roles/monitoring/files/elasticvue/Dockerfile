# syntax=docker/dockerfile:1
# Builds ElasticVue from source so VITE_APP_PUBLIC_PATH can be set at
# build time — required to serve the SPA from the /elasticvue sub-path.
FROM node:lts-alpine AS builder
WORKDIR /app
RUN apk add --no-cache git
ARG ELASTICVUE_REF=master
RUN git clone --depth 1 --branch ${ELASTICVUE_REF} \
    https://github.com/cars10/elasticvue.git .
RUN yarn install --frozen-lockfile
RUN VITE_APP_BUILD_MODE=docker VITE_APP_PUBLIC_PATH=/elasticvue/ yarn build

FROM nginx:alpine
COPY --from=builder /app/dist /usr/share/nginx/html/elasticvue
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 8080
