FROM alpine:3.20

ARG ZIG_VERSION=0.13.0
ARG ZCACHED_VERSION=0.0.1

RUN addgroup -S zcached && adduser -S zcached -G zcached
ENV APP_DIR /home/zcached/build
RUN mkdir ${APP_DIR} && chown zcached:zcached ${APP_DIR}

WORKDIR ${APP_DIR}
USER zcached

# Download and extract zig
RUN wget https://ziglang.org/download/$ZIG_VERSION/zig-linux-x86_64-$ZIG_VERSION.tar.xz
RUN tar -xJf zig-linux-x86_64-$ZIG_VERSION.tar.xz; rm -rf zig-linux-x86_64-$ZIG_VERSION.tar.xz

RUN mkdir source
COPY --chown=zcached:zcached . ./source

# build and move app to ${APP_DIR}/zcached
RUN cd source && ../zig-linux-x86_64-$ZIG_VERSION/zig build && \
    mv ./zig-out/bin/zcached ${APP_DIR}/zcached

# clean things up.
RUN rm -rf zig-cache zig-out zig-linux-x86_64-$ZIG_VERSION && cd ${APP_DIR}

ENTRYPOINT ["./zcached"]
