FROM alpine:3.21 AS build
WORKDIR /app
COPY . .
RUN echo "Build stage placeholder"

FROM alpine:3.21 AS runtime
WORKDIR /app
COPY --from=build /app .
CMD ["echo", "Hello from Docker"]
