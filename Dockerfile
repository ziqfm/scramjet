# Stage 1: WASM Rewriter
FROM rust:slim-bookworm AS wasm-builder

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    build-essential pkg-config binaryen git ca-certificates curl

RUN rustup toolchain install nightly \
    && rustup target add wasm32-unknown-unknown --toolchain nightly \
    && rustup component add rust-src --toolchain nightly

RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    cargo install wasm-bindgen-cli --version 0.2.105 && \
    cargo install wasm-snip --git https://github.com/r58Playz/wasm-snip

WORKDIR /build
COPY . .

# Extreme Cargo Optimizations
ENV CARGO_PROFILE_RELEASE_LTO="fat"
ENV CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1
ENV CARGO_PROFILE_RELEASE_STRIP="symbols"
ENV CARGO_PROFILE_RELEASE_OPT_LEVEL="3" 

RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/build/packages/core/target \
    cd packages/core && RELEASE=1 OPTIMIZE_FOR_SPEED=1 bash rewriter/wasm/build.sh


# Stage 2: JS/TS Build
FROM node:22-alpine AS js-builder

RUN corepack enable && corepack prepare pnpm@latest --activate
RUN apk add --no-cache git python3 make g++

WORKDIR /build
COPY . .

# Run the install
RUN --mount=type=cache,target=/root/.local/share/pnpm/store \
    pnpm install --frozen-lockfile || pnpm install

# Copy optimized WASM artifacts from stage 1
COPY --from=wasm-builder /build/packages/core/dist/scramjet.wasm packages/core/dist/
COPY --from=wasm-builder /build/packages/core/rewriter/wasm/out/ packages/core/rewriter/wasm/out/

RUN pnpm build
RUN cd packages/demo && npx vite build

# Setup minimal production server directory
RUN mkdir /prod-server \
    && cp /build/packages/demo/dist /prod-server/static -r \
    && cd /prod-server \
    && npm init -y \
    && npm install @mercuryworkshop/wisp-js@0.4.1


# Stage 3: Production Runtime (Distroless)
FROM oven/bun:distroless AS runtime

WORKDIR /app

# Volatility Layering
# Layer 1: Ultra-stable (3rd party node_modules)
COPY --from=js-builder /prod-server/node_modules ./node_modules

# Layer 2: Semi-stable (Server routing logic)
COPY server.prod.mjs ./server.prod.mjs

# Layer 3: Highly Volatile (Static UI assets + compiled WASM)
COPY --from=js-builder /prod-server/static ./static

ENV PORT=4141
EXPOSE 4141

CMD ["bun", "run", "server.prod.mjs"]
