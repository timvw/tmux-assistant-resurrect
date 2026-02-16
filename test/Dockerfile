FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Core tools
RUN apt-get update && apt-get install -y \
    tmux \
    jq \
    bash \
    curl \
    git \
    procps \
    nodejs \
    npm \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# Install just
RUN curl -sSf https://just.systems/install.sh | bash -s -- --to /usr/local/bin

# Install real assistant CLIs (no mocks)
# Pin major versions to prevent upstream breaking changes from failing CI.
# codex is pre-1.0 (0.x), so pin to ~0 (any 0.x); claude-code is 2.x; opencode-ai is 1.x.
RUN npm install -g "@anthropic-ai/claude-code@^2" "@openai/codex@^0" "opencode-ai@^1"

# Verify the binaries exist
RUN which claude && which codex && which opencode

# Create a test user (avoid running as root — tmux behaves differently)
RUN useradd -m -s /bin/bash testuser
USER testuser
WORKDIR /home/testuser

# Copy the repo in (done as testuser for correct ownership)
COPY --chown=testuser:testuser . /home/testuser/tmux-assistant-resurrect

ENTRYPOINT ["bash", "/home/testuser/tmux-assistant-resurrect/test/run-tests.sh"]
