## Building from Source
### Prerequisites
- [zig](https://ziglang.org/download/) (0.12.0 or newer)
- Unix-based operating system (Linux, macOS). For Windows users, please refer to the Docker section below.

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
zig build run
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
