# Eval runner: Linux, so the eval sandbox is bubblewrap and git works inside it.
FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bubblewrap socat git python3 ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash eval
USER eval
WORKDIR /home/eval

ARG CLAUDE_VERSION=2.1.280
RUN curl -fsSL https://claude.ai/install.sh | bash -s "${CLAUDE_VERSION}"
ENV PATH="/home/eval/.local/bin:${PATH}"

RUN git config --global user.email eval@example.invalid \
 && git config --global user.name eval \
 && git config --global init.defaultBranch main
