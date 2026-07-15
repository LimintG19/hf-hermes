FROM python:3.11-slim

LABEL maintainer="Hermes Agent Community"
LABEL version="0.10.0"
LABEL description="Hermes Agent v0.10.0 with Web UI on Hugging Face Spaces"

# 可通过 --build-arg HERMES_WEB_UI_VERSION=0.6.0 覆盖
# ARG HERMES_WEB_UI_VERSION=0.6.3
# ARG HERMES_WEB_UI_VERSION=0.6.7
ARG HERMES_WEB_UI_VERSION=latest

# ==================== 环境变量 ====================
ENV PYTHONUNBUFFERED=1
ENV DEBIAN_FRONTEND=noninteractive
ENV HERMES_HOME=/data/.hermes
ENV PYTHONPATH=/app

# BFF Server 环境变量（构建阶段）
ENV PORT=7860
ENV UPSTREAM=http://127.0.0.1:8642
ENV HERMES_BIN=/usr/local/bin/hermes
# 注意：NODE_ENV=production 不能在此设置！
# npm install 在 NODE_ENV=production 时会跳过 devDependencies，
# 导致 vue-tsc 等构建工具缺失。NODE_ENV 在运行时阶段再设置。

# ==================== 系统依赖 ====================
RUN apt-get update && apt-get install -y \
    ffmpeg \
    git \
    curl \
    unzip \
    ca-certificates \
    make gcc g++ \
    && rm -rf /var/lib/apt/lists/*

# ==================== Node.js v23 ====================
# hermes-web-ui 要求 Node >= 23.0.0
RUN ARCH=$(dpkg --print-architecture) \
    && if [ "$ARCH" = "amd64" ]; then NODE_ARCH="x64"; else NODE_ARCH="$ARCH"; fi \
    && echo "Installing Node.js v23.11.0 for ${NODE_ARCH}" \
    && curl -fsSL "https://nodejs.org/dist/v23.11.0/node-v23.11.0-linux-${NODE_ARCH}.tar.gz" \
       -o /tmp/node.tar.gz \
    && tar -xzf /tmp/node.tar.gz -C /usr/local --strip-components=1 \
    && rm -f /tmp/node.tar.gz \
    && node --version \
    && npm --version

# ==================== Bun Runtime ====================
# baoyu-skills 需要 bun 运行时
# 安装到 /usr/local/bin 以便所有用户（包括 appuser）都能访问
RUN echo "Installing Bun runtime" \
    && curl -fsSL https://bun.sh/install | bash \
    && export PATH="$PATH:/root/.bun/bin" \
    && bun --version \
    && cp /root/.bun/bin/bun /usr/local/bin/bun \
    && chmod +x /usr/local/bin/bun

# bun 必须在运行时 PATH 中可用（agent 子进程通过 bun 调用 baoyu-skills）
# /usr/local/bin 已在默认 PATH 中，所有用户均可访问

# ==================== baoyu-skills 脚本预置 ====================
# 将完整的 baoyu-imagine 脚本预置到 ~/.baoyu-skills/ 目录
# 此目录是 main.ts loadExtendConfig() 的查找路径之一
# 避免依赖 Web UI 技能安装（可能只下载编译产物而丢失 .ts 源文件）
RUN mkdir -p /home/appuser/.baoyu-skills/baoyu-imagine && \
    git clone --depth 1 https://github.com/JimLiu/baoyu-skills.git /tmp/baoyu-skills && \
    cp -r /tmp/baoyu-skills/skills/baoyu-image-gen/scripts \
          /home/appuser/.baoyu-skills/baoyu-imagine/scripts && \
    rm -rf /tmp/baoyu-skills

# ==================== 工具安装 ====================
# yq: 运行时修改 config.yaml
RUN curl -sL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /usr/bin/yq && \
    chmod +x /usr/bin/yq

# ==================== Python 依赖 ====================
COPY requirements.txt /tmp/
RUN pip install --no-cache-dir --prefer-binary -r /tmp/requirements.txt

# ==================== Hermes Agent ====================
# 克隆并安装 Hermes Agent（不再构建内置 Dashboard 前端，由 hermes-web-ui 替代）
# 将源码保留在 /usr/local/lib/hermes-agent 目录下，以便 agent-bridge 和 run_agent.py 能正确集成与相互调用
RUN git clone --depth 1 https://github.com/NousResearch/hermes-agent.git /usr/local/lib/hermes-agent && \
    pip install --no-cache-dir --prefer-binary /usr/local/lib/hermes-agent[all]

# Playwright 浏览器（Hermes Agent 工具调用需要）
RUN npx playwright install chromium --with-deps --only-shell && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# ==================== Hermes Web UI ====================
# 直接安装 npm 发布的预构建包，彻底避免从源码克隆、安装 devDependencies 和编译（节省数分钟及大量 CPU/内存资源）
# npm 包已包含 dist/(server|client|website) 以及 agent-bridge/hermes_bridge.py
RUN mkdir -p /opt/hermes-web-ui && cd /opt/hermes-web-ui && \
    npm init -y && \
    npm install hermes-web-ui@${HERMES_WEB_UI_VERSION} --no-audit --no-fund --loglevel=error && \
    ln -sf node_modules/hermes-web-ui/dist dist && \
    ln -sf node_modules/hermes-web-ui/package.json package.json && \
    rm -rf /root/.npm /opt/hermes-web-ui/package-lock.json

# ==================== 应用代码 ====================
WORKDIR /app

COPY src/ /app/src/
COPY entrypoint.sh /app/
COPY image-proxy.js /app/
COPY image-gen-siliconflow.ts /app/
COPY config/config.yaml /data/.hermes/config.yaml

# 创建数据目录
RUN mkdir -p /data/.hermes /data/.hermes-web-ui /app/logs /home/appuser/.hermes-web-ui/logs && \
    chmod +x /app/entrypoint.sh

# 设置非 root 用户（Hugging Face Spaces 要求）
RUN useradd -m -u 1000 appuser && \
    ln -sf /data/.hermes /home/appuser/.hermes && \
    mkdir -p /home/appuser/.cache && \
    chown -R appuser:appuser /data /opt/hermes-web-ui /app /home/appuser /usr/local/lib/hermes-agent && \
    chown appuser:appuser /usr/local/bin

USER appuser

# ==================== 运行时环境变量 ====================
# 构建阶段不设 NODE_ENV=production（会导致 npm install 跳过 devDependencies）
# 此处设置，仅影响运行时行为
ENV NODE_ENV=production

# 7860: BFF Server (Web UI 入口，HF Spaces 要求)
# 8642: Gateway API Server (BFF 的上游代理目标，仅容器内部)
EXPOSE 7860

HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=3 \
    CMD curl -f http://localhost:7860/health || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]

