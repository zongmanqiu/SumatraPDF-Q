import { $ } from "bun";
import { join } from "node:path";

// Builds the Rust static lib that powers CAJ support, into out/cajshim (gitignored).
// SumatraPDF is linked /MT, so the Rust side must use a static CRT too: mixing a
// dynamic-CRT static lib into it gives two heaps and corrupts the one Rust allocated in.
const root = join(import.meta.dir, "..");
process.env.RUSTFLAGS = "-C target-feature=+crt-static";

await $`cargo build --release --locked --manifest-path ${join(root, "ext/cajshim/Cargo.toml")} --target-dir ${join(root, "out/cajshim")}`;
