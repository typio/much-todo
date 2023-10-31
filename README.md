# Much Todo About Nothing &nbsp; <sub>[![](https://tokei.rs/b1/github/typio/much-todo)](https://github.com/typio/much-todo) ![Uptime Robot ratio (7 days)](https://img.shields.io/uptimerobot/ratio/7/m795572920-cba6912bdf1aa8d654e76cf8?style=plastic)
</sub>


[_Much Todo About Nothing_](https://muchtodo.app) will be a modern, feature-rich todo list web application.

Live at [muchtodo.app](https://muchtodo.app). <sup>(*unless it crashed*)</sup>

## Using the **HOT JazZ** stack

**H**TML + **O**Caml + **T**ypeScript + **J**SON + **a**nd + **z**ippy + **Z**ig

- Frontend (HTML/TailwindCSS/TypeScript)
- Backend Todo App (OCaml)
- Backend Custom Web Server (Zig)

## Building

The web server build process is very ad hoc to my specific setup of building for an x86_64 linux server on aarch64 macos. The only difficulty in building is acquiring openssl for the target platform and linking to it in `build.zig`.