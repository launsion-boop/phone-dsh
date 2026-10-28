// SPDX-License-Identifier: MIT
// WASI client used as the `python3` program in the G2-FIX-61 regression
// test. It takes the same `-c <program>` shape a real one-liner uses, writes
// `<count>` files under `<dir>`, then (with the `:trap` suffix) aborts the
// instance the way a crashing interpreter does. Relative paths resolve from
// PWD like the CPython cwd shim, so `<dir>` is the shell's cwd.
use std::env;
use std::fs;
use std::io::Write;

fn main() {
    let args: Vec<String> = env::args().collect();
    if let Ok(pwd) = env::var("PWD") {
        if pwd.starts_with('/') {
            let _ = env::set_current_dir(&pwd);
        }
    }
    let spec = if args.get(1).map(|value| value.as_str()) == Some("-c") {
        args.get(2).cloned().unwrap_or_default()
    } else {
        args.get(1).cloned().unwrap_or_default()
    };
    let mut parts = spec.split(':');
    let count: usize = parts.next().and_then(|value| value.parse().ok()).unwrap_or(3);
    let dir = parts.next().unwrap_or("frames").to_string();
    let trap = parts.next().map(|value| value == "trap").unwrap_or(false);
    fs::create_dir_all(&dir).unwrap();
    for index in 0..count {
        let path = format!("{}/{}.bin", dir, index);
        let mut file = fs::File::create(&path).unwrap();
        file.write_all(&vec![index as u8; 4096]).unwrap();
    }
    println!("wrote {} to {}", count, dir);
    if trap {
        panic!("simulated interpreter abort after the writes");
    }
}
