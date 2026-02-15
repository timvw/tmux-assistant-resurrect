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
    && rm -rf /var/lib/apt/lists/*

# Install just
RUN curl -sSf https://just.systems/install.sh | bash -s -- --to /usr/local/bin

# Install real assistant CLIs (no mocks)
RUN npm install -g @anthropic-ai/claude-code @openai/codex opencode-ai

# Verify the binaries exist
RUN which claude && which codex && which opencode

# Create a test user (avoid running as root — tmux behaves differently)
RUN useradd -m -s /bin/bash testuser
USER testuser
WORKDIR /home/testuser

# Copy the repo in (done as testuser for correct ownership)
COPY --chown=testuser:testuser . /home/testuser/tmux-assistant-resurrect

ENTRYPOINT ["bash", "/home/testuser/tmux-assistant-resurrect/test/run-tests.sh"]
