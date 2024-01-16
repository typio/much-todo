# Much Todo About Nothing &nbsp; <sub>![Uptime Robot ratio (30 days)](https://img.shields.io/uptimerobot/ratio/m795572920-cba6912bdf1aa8d654e76cf8?style=plastic)
</sub>

[_Much Todo About Nothing_](https://muchtodo.app) will be a modern, feature-rich note-taking / todo list web application.

Live at [muchtodo.app](https://muchtodo.app). <sup>(*unless it crashed*)</sup>

## Using the **HOT JazZ** stack

**H**TML + **O**Caml + **T**ypeScript + **J**SON + **a**nd + **z**ippy + **Z**ig

- Frontend 👉 HTML/TypeScript
- Backend App 👉 OCaml/JSON
- Backend Web Server 👉 Zig

## Building

The web server build process is very ad hoc to my specific setup of building for an x86_64 linux server on aarch64 macos. The only difficulty in building is acquiring openssl for the target platform and linking to it in `build.zig`.