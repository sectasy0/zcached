FROM alpine:3.20

ARG ZIG_VERSION=0.12.0
ARG ZCACHED_VERSION=0.0.1

WORKDIR /zcached

RUN wget https://ziglang.org/download/$ZIG_VERSION/zig-linux-x86_64-$ZIG_VERSION.tar.xz 
RUN tar -xJf zig-linux-x86_64-$ZIG_VERSION.tar.xz
RUN mv zig-linux-x86_64-$ZIG_VERSION/* .

RUN wget https://github.com/sectasy0/zcached/archive/refs/tags/$ZCACHED_VERSION.tar.gz
RUN tar -xf $ZCACHED_VERSION.tar.gz
RUN mv zcached-$ZCACHED_VERSION/* .

RUN rm -rf zcached-$ZCACHED_VERSION $ZCACHED_VERSION.tar.gz zig-linux-x86_64-$ZIG_VERSION.tar.xz zig-linux-x86_64-$ZIG_VERSION