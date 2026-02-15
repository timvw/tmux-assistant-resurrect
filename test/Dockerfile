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
    && rm -rf /var/lib/apt/lists/*

# Install just
RUN curl -sSf https://just.systems/install.sh | bash -s -- --to /usr/local/bin

# Create mock assistant binaries that sleep forever (mimic real processes).
# IMPORTANT: Must NOT use `exec sleep` — that replaces the process image and
# the binary name disappears from `ps`. Instead, use a trap+wait loop so the
# shell stays alive with the original command visible in the process table.

RUN printf '#!/bin/bash\ntrap "exit 0" TERM INT\nwhile true; do sleep 3600 & wait $!; done\n' > /usr/local/bin/claude && \
    chmod +x /usr/local/bin/claude

RUN printf '#!/bin/bash\ntrap "exit 0" TERM INT\nwhile true; do sleep 3600 & wait $!; done\n' > /usr/local/bin/opencode && \
    chmod +x /usr/local/bin/opencode

RUN printf '#!/bin/bash\ntrap "exit 0" TERM INT\nwhile true; do sleep 3600 & wait $!; done\n' > /usr/local/bin/codex && \
    chmod +x /usr/local/bin/codex

# Create a test user (avoid running as root — tmux behaves differently)
RUN useradd -m -s /bin/bash testuser
USER testuser
WORKDIR /home/testuser

# Copy the repo in (done as testuser for correct ownership)
COPY --chown=testuser:testuser . /home/testuser/tmux-assistant-resurrect

ENTRYPOINT ["bash", "/home/testuser/tmux-assistant-resurrect/test/run-tests.sh"]
