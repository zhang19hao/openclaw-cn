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

RUN RUN pnpm install --ignore-scripts

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

# 复制构建产物和扩展
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/package.json /app/pnpm-lock.yaml /app/pnpm-workspace.yaml ./
# 复制扩展（插件）目录，包括所有已编译的依赖
COPY --from=builder /app/extensions ./extensions
# 复制运行时所需的文档（templates 用于 agent 任务）
COPY --from=builder /app/docs ./docs

# 仅安装生产依赖
RUN pnpm install --frozen-lockfile --production --ignore-scripts

# 清理缓存以减小镜像大小
RUN pnpm store prune

ENV NODE_ENV=production

# 安全加固：以非 root 用户运行
# node:22-bookworm 镜像包含 'node' 用户（uid 1000）
# 这通过防止容器逃逸来减少攻击面
USER node

CMD ["node", "dist/index.js"]
