FROM alpine:3.20

ARG ZIG_VERSION=0.12.0
ARG ZCACHED_VERSION=0.0.1

RUN addgroup -S zcached && adduser -S zcached -G zcached
ENV APP_DIR /home/zcached/build
RUN mkdir ${APP_DIR} && chown zcached:zcached ${APP_DIR}

WORKDIR ${APP_DIR}
USER zcached

RUN wget https://ziglang.org/download/$ZIG_VERSION/zig-linux-x86_64-$ZIG_VERSION.tar.xz
RUN tar -xJf zig-linux-x86_64-$ZIG_VERSION.tar.xz; rm -rf zig-linux-x86_64-$ZIG_VERSION.tar.xz

RUN mkdir source
COPY --chown=zcached:zcached . ./source

# RUN mv zcached.conf.example zcached.conf
RUN ./zig-linux-x86_64-$ZIG_VERSION/zig build && \
		mv ./source/zig-out/bin/zcached ${APP_DIR}/zcached

# clean things up.
RUN rm -rf zig-cache zig-out zig-linux-x86_64-$ZIG_VERSION

ENTRYPOINT ["./zcached"]
