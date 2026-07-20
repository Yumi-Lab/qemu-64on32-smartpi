FROM arm64v8/debian:bookworm

RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    curl \
    wget \
    ca-certificates \
    pkg-config \
    python3 \
    python3-venv \
    meson \
    ninja-build \
    flex \
    bison \
    && rm -rf /var/lib/apt/lists/*

RUN dpkg --add-architecture armhf

RUN apt-get update && apt-get install -y \
    crossbuild-essential-armhf \
    libglib2.0-dev:armhf \
    zlib1g-dev:armhf \
    libpcre2-dev:armhf \
    libcapstone-dev:armhf \
    && rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y \
    gcc-aarch64-linux-gnu \
    binutils-aarch64-linux-gnu \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /workspace
WORKDIR /workspace
