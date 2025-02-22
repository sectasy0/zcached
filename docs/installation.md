## Building from Source
### Prerequisites
- [zig](https://ziglang.org/download/) (0.13.0 or newer)
- Unix-based operating system (Linux, macOS). For Windows users, please refer to the `Docker` section below.

### Steps
**1. Clone the repository.**
```bash
git clone https://github.com/sectasy0/zcached
```
**2. Navigate into the project directory.**
```bash
cd zcached
```
**3. Build the project.**
```bash
# provide --tls-enabled=true to build zcached with tls
zig build
```
**4. Run the executable.**
```bash
./zig-out/bin/zcached
```
---

## Docker 🐳
> zcached source is available under `~/source` inside docker.

### Prerequisites
- [Docker Compose](https://docs.docker.com/compose/install/)
- [docker-compose.yml](https://github.com/sectasy0/zcached/raw/master/docker-compose.yml)
- [zcached.conf.example](https://github.com/sectasy0/zcached/raw/master/zcached.conf.example)

### Steps
**1. Modify the config.**
- Rename the config file from `zcached.conf.example` to `zcached.conf`.
- Change the `address` field to `0.0.0.0`.
- Remove the addresses from the whitelist. The line should look like this: `whitelist=`.

**2. Run the container.**
> Remember to keep the `docker-compose.yml` and `zcached.conf` files in the same directory!
```bash
docker compose up
```

## Installation script

- [zig](https://ziglang.org/download/) (0.13.0 or newer)
- Unix-based operating system (Linux, macOS). For Windows users, please refer to the `Docker` section above.

This process is similar to building from source, but it simplifies the setup by using an installation script to compile and configure `zcached` to run with your system. If you prefer not to use systemd configuration, please refer to the instructions in the `Building from Source` section.

**1. Clone the repository.**
```bash
git clone https://github.com/sectasy0/zcached
```
**2. Run script.**
Ensure that `zig` is available in your system's PATH, or set the `ZIG_ENV` environment variable to specify the path to `zig` if necessary.
```bash
sh install.sh
```
**2. Start zcached.**
```bash
sudo systemctl start zcached.service
```
