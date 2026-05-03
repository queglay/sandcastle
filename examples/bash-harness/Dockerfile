FROM node:22-bookworm

# UID/GID for the in-container `agent` user. Sandcastle's docker provider
# launches the container with `--user $hostUid:$hostGid` so bind-mounted files
# match host ownership. Defaults match macOS dev convention (501:20). On Linux
# hosts where `id -u` is 1000, override at build time:
#   docker build --build-arg USER_UID=$(id -u) --build-arg USER_GID=$(id -g) ...
ARG USER_UID=501
ARG USER_GID=20

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl jq \
    ca-certificates gnupg \
  && rm -rf /var/lib/apt/lists/*

# GitHub CLI (agent prompt uses `gh issue list`, `gh issue close`, etc.)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
  && apt-get update && apt-get install -y --no-install-recommends gh \
  && rm -rf /var/lib/apt/lists/*

# chrome-devtools-mcp for Loop B (playwright-verify) on frontend AFK issues
RUN npm install -g chrome-devtools-mcp@latest

# Playwright + Chromium for in-sandbox UI verification (Loop B).
# Adds ~700 MB. Image grows from ~2.6 GB to ~3.7 GB; acceptable.
#
# PLAYWRIGHT_BROWSERS_PATH is set globally so the install lands at a
# world-readable path (default ~/.cache/ms-playwright is owned by root and
# the agent user can't read it). The stable symlink decouples
# @playwright/mcp's --executable-path from the chromium revision number.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright-browsers
RUN mkdir -p /opt/playwright-browsers \
  && npm install -g @playwright/mcp@latest playwright@latest \
  && npx --yes playwright install --with-deps chromium \
  && ln -sf /opt/playwright-browsers/chromium-*/chrome-linux/chrome /usr/local/bin/playwright-chromium \
  && chmod -R a+rX /opt/playwright-browsers

# ── PROJECT SETUP — customise for your project ──────────────────────────────
# Pre-bake your project's runtime dependencies here for faster sandbox startup.
# Examples:
#
# Python (pip):
#   COPY backend/pyproject.toml /tmp/project-build/pyproject.toml
#   COPY backend/README.md /tmp/project-build/README.md
#   RUN python3 -m venv /opt/project-venv \
#     && /opt/project-venv/bin/pip install --upgrade pip --quiet \
#     && /opt/project-venv/bin/pip install "/tmp/project-build[dev]" --quiet \
#     && rm -rf /tmp/project-build
#   ENV PATH="/opt/project-venv/bin:${PATH}"
#
# Node (npm):
#   COPY package.json package-lock.json /tmp/project-frontend/
#   RUN cd /tmp/project-frontend && npm ci --prefer-offline --no-audit \
#     && mkdir -p /opt/project-deps \
#     && mv /tmp/project-frontend/node_modules /opt/project-deps/node_modules \
#     && rm -rf /tmp/project-frontend
# ────────────────────────────────────────────────────────────────────────────

# Rename the base image's "node" user AND group (UID/GID 1000) to "agent" and
# renumber to USER_UID/USER_GID so it matches the host (Sandcastle runs the
# container as the host UID). On macOS GID 20 ("dialout" in Debian) already
# exists — delete the conflicting group first if so.
RUN getent group ${USER_GID} | grep -qv "^agent:" && groupdel "$(getent group ${USER_GID} | cut -d: -f1)" || true \
  && usermod -d /home/agent -m -l agent node \
  && groupmod -n agent node \
  && groupmod -g ${USER_GID} agent \
  && usermod -u ${USER_UID} -g ${USER_GID} agent \
  && chown -R agent:agent /home/agent

USER agent

# Install Claude Code CLI (per-user install — required because --dangerously-skip-permissions
# refuses to run as root)
COPY --chown=agent:agent .sandcastle/claude-shim.sh /home/agent/.local/bin/claude-shim.sh
RUN curl -fsSL https://claude.ai/install.sh | bash \
  && mv /home/agent/.local/bin/claude /home/agent/.local/bin/claude-real \
  && cp /home/agent/.local/bin/claude-shim.sh /home/agent/.local/bin/claude \
  && chmod +x /home/agent/.local/bin/claude

WORKDIR /home/agent

# Sandcastle bind-mounts the git worktree at /home/agent/workspace at container start.
ENTRYPOINT ["sleep", "infinity"]
