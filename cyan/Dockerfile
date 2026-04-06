FROM oven/bun:1.3.8
WORKDIR /app
LABEL cyanprint.dev=true
COPY package.json .
RUN bun install
COPY . .
CMD ["bun", "run", "index.ts"]
