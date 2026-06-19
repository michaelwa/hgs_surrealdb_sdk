# Installing SurrealDB

This SDK talks to a running [SurrealDB](https://surrealdb.com/docs/surrealdb)
server; it does not bundle one. Choose whichever install method fits your
environment. All three result in a server you can reach over HTTP
(`http://localhost:8000`) or WebSocket (`ws://localhost:8000/rpc`).

## Option 1: Install script (direct install)

```bash
curl -sSf https://install.surrealdb.com | sh
surreal start --user root --pass root memory
```

`memory` runs an ephemeral in-memory store; swap it for a persistent path
(for example `surrealkv://./data` or `rocksdb://./data`) to keep data across restarts.

## Option 2: Docker image

```bash
docker run --rm --pull always -p 8000:8000 surrealdb/surrealdb:latest \
  start --user root --pass root memory
```

## Option 3: Build from source

Requires a [Rust toolchain](https://rustup.rs/).

```bash
git clone https://github.com/surrealdb/surrealdb
cd surrealdb
cargo build --release
./target/release/surreal start --user root --pass root memory
```

## Verify it is running

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8000/health   # expect 200
```

## Create the namespace and database

A fresh server has no namespaces or databases, and connecting to one that does
not exist fails with `The namespace '<name>' does not exist`. Define the targets
once (as `root`) before connecting from the SDK:

```bash
# Define the namespace at the root level.
curl -s -X POST http://localhost:8000/sql -u root:root \
  -H "Accept: application/json" \
  -d "DEFINE NAMESPACE IF NOT EXISTS test;"

# Define the database, scoped to that namespace via the surreal-ns header.
curl -s -X POST http://localhost:8000/sql -u root:root \
  -H "Accept: application/json" -H "surreal-ns: test" \
  -d "DEFINE DATABASE IF NOT EXISTS test;"
```

Use whatever names match your store or client config. `test`/`test` above are
simple local defaults.

Then connect from Elixir per the [Getting Started guide](getting-started.md).
