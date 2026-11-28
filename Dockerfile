FROM alpine:3.20

ARG ZIG_VERSION=0.17.1
ARG ZCACHED_VERSION=0.0.1

RUN apk add --no-cache openssl-dev

RUN addgroup -S zcached && adduser -S zcached -G zcached
ENV APP_DIR /home/zcached/build
RUN mkdir ${APP_DIR} && chown zcached:zcached ${APP_DIR}

WORKDIR ${APP_DIR}
USER zcached

# Download and extract zig
RUN wget https://ziglang.org/download/$ZIG_VERSION/zig-x86_64-linux-$ZIG_VERSION.tar.xz
RUN tar -xJf zig-x86_64-linux-$ZIG_VERSION.tar.xz; rm -f zig-x86_64-linux-$ZIG_VERSION.tar.xz

RUN mkdir source
COPY --chown=zcached:zcached . ./source

# build and move app to ${APP_DIR}/zcached
RUN cd source && ../zig-x86_64-linux-$ZIG_VERSION/zig build && \
    mv ./zig-out/bin/zcached ${APP_DIR}/zcached && \
    mv ./zig-out/bin/zcached-cli ${APP_DIR}/zcached-cli

# clean things up.
RUN rm -rf zig-cache zig-out zig-x86_64-linux-$ZIG_VERSION && cd ${APP_DIR}

ENTRYPOINT ["./zcached"]
