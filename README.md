# capnproto-zig

This repository builds the [Cap'n Proto](https://github.com/capnproto/capnproto)
compiler for Linux, macOS, and Windows using [Zig](https://ziglang.org), then
makes all builds available using [Dotslash](https://dotslash-cli.com); this
makes it easy to depend on Cap'n Proto in any project without having to set up a
C++ toolchain.

The system C and C++ libraries must be installed.

> [!NOTE]
>
> This only wraps the C++ library and binaries, and neither adds bindings nor a
> Zig library / codegen. The name of the project is `capnproto-zig` to avoid
> conflicts with `capnp-zig`, which is typically used for ports to another
> language.

## Usage

Download the latest
[prebuilt release](https://github.com/71/capnproto-zig/releases), and extract
it. Note that releases are published by a GitHub Action and immutable.

```sh
capnproto_zig_version=v0.1.0
curl --fail --location --show-error --remote-name \
  https://github.com/71/capnproto-zig/releases/download/$capnproto_zig_version/linux-x86_64.tar.zst
mkdir capnproto
tar -xvf linux-x86_64.tar.zst -C capnproto
capnproto/bin/capnp --version
```

Alternatively, to use [Dotslash](https://dotslash-cli.com):

```sh
capnproto_zig_version=v0.1.0
curl --fail --location --show-error --remote-name \
  https://github.com/71/capnproto-zig/releases/download/$capnproto_zig_version/capnp
chmod +x capnp
./capnp --version
```
