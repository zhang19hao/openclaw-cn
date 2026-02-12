# 构建阶段（支持多架构）
FROM node:22-bookworm AS builder

# 设置构建参数
ARG TARGETPLATFORM
ARG BUILDPLATFORM
ARG OPENCLAW_DOCKER_APT_PACKAGES=""

# 打印构建信息用于调试
RUN echo "Building for: $TARGETPLATFORM on $BUILDPLATFORM"

# 仅在非 ARM 架构上安装 Bun（ARM 上强制使用 pnpm）
RUN if [ "$TARGETPLATFORM" != "linux/arm64" ]; then \
      curl -fsSL https://bun.sh/install | bash && \
      echo "/root/.bun/bin:$PATH" >> /etc/profile.d/bun.sh; \
    fi

RUN corepack enable

WORKDIR /app

# 可选：安装额外的 apt 包
RUN if [ -n "$OPENCLAW_DOCKER_APT_PACKAGES" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $OPENCLAW_DOCKER_APT_PACKAGES && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

# Configure git to use HTTPS for GitHub (fixes libsignal-node SSH errors)
RUN git config --global url."https://github.com/".insteadOf ssh://git@github.com/
RUN git config --global url."https://".insteadOf git://

# 复制依赖文件并安装（利用 Docker 缓存层）
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY ui/package.json ./ui/package.json
COPY patches ./patches
COPY scripts ./scripts

RUN pnpm install --ignore-scripts

# 复制源码并构建
COPY . .

RUN pnpm build

# 强制在所有架构上使用 pnpm 构建 UI（ARM/Synology 架构上 Bun 可能失败）
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:install
RUN pnpm ui:build

# 运行时阶段（最小化最终镜像大小）
FROM node:22-bookworm

ARG TARGETPLATFORM

RUN corepack enable && \
    echo "Runtime image for: $TARGETPLATFORM"

WORKDIR /app

# 复制运行需要的配置 + 补丁文件（修复 patches 不存在报错）
COPY --from=builder /app/package.json ./
COPY --from=builder /app/pnpm-lock.yaml ./
COPY --from=builder /app/pnpm-workspace.yaml ./
COPY --from=builder /app/patches ./patches

# 复制构建产物
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/extensions ./extensions
COPY --from=builder /app/docs ./docs

# 仅安装生产依赖
RUN pnpm install --frozen-lockfile --production --ignore-scripts

# 清理缓存
RUN pnpm store prune

ENV NODE_ENV=production

# 非 root 运行
USER node

CMD ["node", "dist/index.js"]
