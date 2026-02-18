ARG ERLANG_VERSION=28.1
ARG GLEAM_VERSION=v1.14.0

# Gleam stage
FROM ghcr.io/gleam-lang/gleam:${GLEAM_VERSION}-scratch AS gleam

# Build stage
FROM erlang:${ERLANG_VERSION}-alpine AS build
COPY --from=gleam /bin/gleam /bin/gleam
COPY . /app/
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
