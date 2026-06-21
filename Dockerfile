# Stage 1: WASM Rewriter
FROM rust:slim-bookworm AS wasm-builder

# Expose Docker's target architecture variable to the build stage
ARG TARGETARCH

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    build-essential pkg-config git ca-certificates curl

RUN BINARYEN_VERSION="version_118" && \
    if [ "$TARGETARCH" = "arm64" ]; then ARCH="aarch64"; else ARCH="x86_64"; fi && \
    curl -L "https://github.com/WebAssembly/binaryen/releases/download/${BINARYEN_VERSION}/binaryen-${BINARYEN_VERSION}-${ARCH}-linux.tar.gz" | tar -xz && \
    cp binaryen-${BINARYEN_VERSION}/bin/wasm-opt /usr/local/bin/ && \
    rm -rf binaryen-${BINARYEN_VERSION}

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

ENV WASMOPTFLAGS="--enable-bulk-memory"

# Execute the build script from its native directory
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/build/packages/core/rewriter/target \
    cd packages/core/rewriter/wasm && RELEASE=1 OPTIMIZE_FOR_SPEED=1 bash build.sh


# Stage 2: JS/TS Build
FROM node:22-alpine AS js-builder

RUN corepack enable && corepack prepare pnpm@latest --activate
RUN apk add --no-cache git python3 make g++

WORKDIR /build

COPY . .

# Instant-install via pnpm store cache mount
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

# Layer 1: Ultra-stable (3rd party node_modules)
COPY --from=js-builder /prod-server/node_modules ./node_modules

# Layer 2: Semi-stable (Server routing logic)
COPY server.prod.mjs ./server.prod.mjs

# Layer 3: Highly Volatile (Static UI assets + compiled WASM)
COPY --from=js-builder /prod-server/static ./static

ENV PORT=4141
EXPOSE 4141

# Exec form is MANDATORY in distroless
CMD ["bun", "run", "server.prod.mjs"]
