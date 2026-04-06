FROM alpine:3.22 as base
# hadolint ignore=DL3018,DL3019
RUN apk add tar

FROM base as build
WORKDIR /src
COPY . .
RUN rm -rf cyan && mkdir -p /cyanprint/artifact && tar -czvf /cyanprint/artifact/cyan.tar.gz /src/

FROM base
LABEL cyanprint.dev=true
COPY --from=build /cyanprint/artifact/cyan.tar.gz  /cyanprint/artifact/cyan.tar.gz
WORKDIR /workspace
CMD [ "tar",  "-xzf",  "/cyanprint/artifact/cyan.tar.gz", "-C", "/workspace/cyanprint", "--strip-components=1" ]
