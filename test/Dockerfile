FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Core tools + build deps for bash 3.2
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
    gcc \
    make \
    && rm -rf /var/lib/apt/lists/*

# Install bash 3.2 from source (macOS ships bash 3.2; needed for awk-fallback tests)
# SHA256 pinned for reproducibility (GPG sig also at bash-3.2.tar.gz.sig on ftp.gnu.org).
RUN BASH32_SHA256="26c99025b59e30779300b68adb764f824974d267a4d7cc1b347d14a2393f9fb4" && \
    curl -sSfL -o /tmp/bash-3.2.tar.gz https://ftp.gnu.org/gnu/bash/bash-3.2.tar.gz \
    && echo "$BASH32_SHA256  /tmp/bash-3.2.tar.gz" | sha256sum -c - \
    && tar xz -C /tmp -f /tmp/bash-3.2.tar.gz \
    && ARCH=$(uname -m) \
    && case "$ARCH" in x86_64) TRIPLE="x86_64-pc-linux-gnu";; aarch64) TRIPLE="aarch64-unknown-linux-gnu";; *) TRIPLE="$ARCH-pc-linux-gnu";; esac \
    && cd /tmp/bash-3.2 \
    && ./configure --build="$TRIPLE" --prefix=/usr/local --without-bash-malloc >/dev/null 2>&1 \
    && make -j"$(nproc)" >/dev/null 2>&1 \
    && cp bash /usr/local/bin/bash3.2 \
    && rm -rf /tmp/bash-3.2 /tmp/bash-3.2.tar.gz

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

# TEST_BASH: override bash used by scripts under test (save/restore).
# "bash" (default) = system bash 5; "bash3.2" = bash 3.2 awk-fallback path.
# The test harness itself always runs under bash 5 (explicit in ENTRYPOINT).
ENV TEST_BASH="bash"
ENTRYPOINT ["/bin/bash", "/home/testuser/tmux-assistant-resurrect/test/run-tests.sh"]
