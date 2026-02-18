ARG ERLANG_VERSION=28.1
ARG GLEAM_VERSION=v1.14.0
ARG NODE_VERSION=25

# Tailwind stage
FROM node:${NODE_VERSION}-alpine AS tailwind

WORKDIR /app/server

COPY server/package.json server/package-lock.json ./
RUN npm ci

COPY server/assets ./assets

RUN mkdir -p /app/server/priv/static/css/
RUN npx @tailwindcss/cli \
    -i /app/server/assets/css/app.css \
    -o /app/server/priv/static/css/app.css

# Gleam stage
FROM ghcr.io/gleam-lang/gleam:${GLEAM_VERSION}-scratch AS gleam

# Build stage
FROM erlang:${ERLANG_VERSION}-alpine AS build
COPY --from=gleam /bin/gleam /bin/gleam
COPY . /app/

COPY --from=tailwind /app/server/priv/static/css/app.css \
    /app/server/priv/static/css/app.css

RUN cd /app/server && gleam export erlang-shipment

# Final stage
FROM erlang:${ERLANG_VERSION}-alpine
ARG GIT_SHA
ARG BUILD_TIME
ENV GIT_SHA=${GIT_SHA}
ENV BUILD_TIME=${BUILD_TIME}
COPY server/healthcheck.sh /app/healthcheck.sh
RUN \
    chmod +x /app/healthcheck.sh \
    && addgroup --system webapp \
    && adduser --system webapp -g webapp
USER webapp
COPY --from=build /app/server/build/erlang-shipment /app
WORKDIR /app
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]
