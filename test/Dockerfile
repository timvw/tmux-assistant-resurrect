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
    python3 \
    gcc \
    make \
    ca-certificates \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 22.x (Pi requires >= 22.19.0; Ubuntu 24.04 ships Node 18)
# No mirror exists for this one, so retry is all that is available; a truncated
# download would otherwise surface as the apt-get below failing to find nodejs.
RUN curl -fsSL --connect-timeout 15 --retry 3 --retry-delay 2 \
      https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install bash 3.2 from source (macOS ships bash 3.2; needed for awk-fallback tests)
# SHA256 pinned for reproducibility (GPG sig also at bash-3.2.tar.gz.sig on ftp.gnu.org).
#
# Taken from the first mirror that serves the expected bytes, rather than from
# ftp.gnu.org alone. A GNU infrastructure outage made that host unroutable from
# GitHub runners for hours, and with no timeout each job spent ~135s connecting
# before failing the build — the same infrastructure-failure-reads-as-product-
# failure problem the `just` block below describes, except it took out every
# Docker job at once.
#
# The checksum is verified INSIDE the loop, which is what makes mirrors safe and
# is also why a bad one is survivable: a mirror that answers 200 with a stale or
# truncated body fails verification and we move on to the next host instead of
# failing the build. `tar` is only ever reached through `break`, and `break` is
# only reachable once sha256sum has approved the file in that same iteration, so
# a wrong tarball can never be unpacked. If no URL yields a verified file the
# loop exits non-zero on its last command and the `&&` chain stops here.
#
# Three timeouts, because they bound different failures: --connect-timeout only
# covers the handshake, so --speed-time/--speed-limit aborts a peer that connects
# and then stalls mid-transfer, and --max-time is the backstop (300s against a
# ~3MB download that normally takes about two seconds).
RUN BASH32_SHA256="26c99025b59e30779300b68adb764f824974d267a4d7cc1b347d14a2393f9fb4" \
    && for url in \
        https://ftp.gnu.org/gnu/bash/bash-3.2.tar.gz \
        https://mirrors.ocf.berkeley.edu/gnu/bash/bash-3.2.tar.gz \
        https://mirror.us-midwest-1.nexcess.net/gnu/bash/bash-3.2.tar.gz; \
       do \
         echo "bash 3.2: fetching from ${url}" \
         && curl -sSfL --connect-timeout 15 --max-time 300 \
              --speed-limit 1024 --speed-time 30 \
              --retry 2 --retry-delay 2 \
              -o /tmp/bash-3.2.tar.gz "$url" \
         && echo "$BASH32_SHA256  /tmp/bash-3.2.tar.gz" | sha256sum -c - \
         && break; \
       done \
    && tar xz -C /tmp -f /tmp/bash-3.2.tar.gz \
    && ARCH=$(uname -m) \
    && case "$ARCH" in x86_64) TRIPLE="x86_64-pc-linux-gnu";; aarch64) TRIPLE="aarch64-unknown-linux-gnu";; *) TRIPLE="$ARCH-pc-linux-gnu";; esac \
    && cd /tmp/bash-3.2 \
    && ./configure --build="$TRIPLE" --prefix=/usr/local --without-bash-malloc >/dev/null 2>&1 \
    && make -j"$(nproc)" >/dev/null 2>&1 \
    && cp bash /usr/local/bin/bash3.2 \
    && rm -rf /tmp/bash-3.2 /tmp/bash-3.2.tar.gz

# Install just from a pinned release, SHA256 verified per architecture.
# Deliberately NOT `curl https://just.systems/install.sh | bash`: that endpoint
# returns 403 often enough to have failed this build twice, and because it runs
# during image build the whole job dies before a single test executes — which
# reads as a product failure rather than an infrastructure one. A pinned tarball
# also makes the image reproducible, matching how bash 3.2 and the npm packages
# are handled above.
RUN JUST_VERSION="1.58.0" && \
    case "$(uname -m)" in \
      x86_64)  JUST_ARCH="x86_64-unknown-linux-musl";  JUST_SHA256="4a5cc2f53e6f0f8c59092a6cc38291eb729d46a7dd95d3ae582008881b84931d" ;; \
      aarch64) JUST_ARCH="aarch64-unknown-linux-musl"; JUST_SHA256="748237128c4c40cbdabc65e841d05ceba13cc23a91eaba395495894c1d9764df" ;; \
      *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac \
    && curl -sSfL --retry 3 --retry-delay 2 \
        -o /tmp/just.tar.gz \
        "https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-${JUST_ARCH}.tar.gz" \
    && echo "${JUST_SHA256}  /tmp/just.tar.gz" | sha256sum -c - \
    && tar xz -C /usr/local/bin -f /tmp/just.tar.gz just \
    && rm -f /tmp/just.tar.gz \
    && just --version

# Install Bun (Oh My Pi's published `omp` bin uses a Bun shebang).
RUN curl -fsSL --connect-timeout 15 --retry 3 --retry-delay 2 \
      https://bun.sh/install | bash -s "bun-v1.3.14" \
    && install -m 0755 /root/.bun/bin/bun /usr/local/bin/bun \
    && rm -rf /root/.bun

# Install real assistant CLIs (no mocks)
# Pin major versions to prevent upstream breaking changes from failing CI.
# codex is pre-1.0 (0.x), so pin to ~0 (any 0.x); claude-code is 2.x;
# opencode-ai is 1.x; pi-coding-agent is 0.x (requires Node >= 22.19.0);
# Oh My Pi is 16.x and requires Bun for its `omp` entrypoint; Copilot is 1.x.
RUN npm install -g "@anthropic-ai/claude-code@^2" "@github/copilot@^1" "@openai/codex@^0" "opencode-ai@^1" "@earendil-works/pi-coding-agent@^0" "@oh-my-pi/pi-coding-agent@^16" "@xai-official/grok@^1"

# Verify the binaries exist
RUN which claude && which copilot && copilot --version && which codex && which opencode && which pi && which omp && omp --version && which grok && grok --version

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
