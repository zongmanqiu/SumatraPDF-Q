//! Thin extern-C shim over `caj2pdf-core`.
//!
//! Boundary rules (see .plan/m02b-inline-ffi.md):
//!   * nothing allocated here crosses the boundary; the C++ side only ever
//!     passes plain paths and a caller-owned char buffer.
//!   * every entry point is wrapped in catch_unwind so a Rust panic can never
//!     unwind into MSVC code that uses setjmp.

use std::cell::RefCell;
use std::ffi::{c_char, c_int, CStr};
use std::io::BufWriter;
use std::panic::{catch_unwind, AssertUnwindSafe};

thread_local! {
    static LAST_ERROR: RefCell<String> = const { RefCell::new(String::new()) };
}

fn set_last_error(msg: String) {
    LAST_ERROR.with(|e| *e.borrow_mut() = msg);
}

fn to_path<'a>(s: &'a CStr) -> Option<&'a str> {
    s.to_str().ok()
}

/// Convert a CAJ-family file into a PDF file. Both paths are UTF-8.
/// Returns 0 on success; non-zero leaves a message for caj_last_error().
#[no_mangle]
pub extern "C" fn caj_convert_file(src: *const c_char, dst: *const c_char) -> c_int {
    if src.is_null() || dst.is_null() {
        set_last_error("null path".to_string());
        return 3;
    }
    let src_c = unsafe { CStr::from_ptr(src) };
    let dst_c = unsafe { CStr::from_ptr(dst) };
    let (src_s, dst_s) = match (to_path(src_c), to_path(dst_c)) {
        (Some(s), Some(d)) => (s, d),
        _ => {
            set_last_error("path is not valid UTF-8".to_string());
            return 3;
        }
    };

    let res = catch_unwind(AssertUnwindSafe(|| do_convert(src_s, dst_s)));
    match res {
        Ok(Ok(())) => 0,
        Ok(Err(e)) => {
            set_last_error(e);
            1
        }
        Err(panic) => {
            let msg = panic
                .downcast_ref::<&str>()
                .map(|s| (*s).to_string())
                .or_else(|| panic.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "panicked without a message".to_string());
            set_last_error(format!("internal error: {}", msg));
            2
        }
    }
}

/// Copy the last error message into a caller-owned buffer (truncating).
/// Returns the number of bytes written, excluding the terminator.
#[no_mangle]
pub extern "C" fn caj_last_error(buf: *mut c_char, buf_len: c_int) -> c_int {
    if buf.is_null() || buf_len <= 0 {
        return 0;
    }
    let msg = LAST_ERROR.with(|e| e.borrow().clone());
    let bytes = msg.as_bytes();
    let n = bytes.len().min((buf_len - 1) as usize);
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf as *mut u8, n);
        *buf.add(n) = 0;
    }
    n as c_int
}

#[no_mangle]
pub extern "C" fn caj_shim_version() -> *const c_char {
    concat!("cajshim/0.1 caj2pdf-core/0.8.1\0").as_ptr() as *const c_char
}

fn do_convert(src: &str, dst: &str) -> Result<(), String> {
    let file = std::fs::File::open(src).map_err(|e| format!("cannot open '{}': {}", src, e))?;
    let mut input = caj2pdf_core::native::SeekableSource::new(file).map_err(|e| format!("{}", e))?;
    let out = std::fs::File::create(dst).map_err(|e| format!("cannot create '{}': {}", dst, e))?;
    let mut writer = BufWriter::new(out);
    caj2pdf_core::convert(
        &mut input,
        &mut writer,
        caj2pdf_core::ConversionOptions::default(),
        &caj2pdf_core::Limits::default(),
        &mut caj2pdf_core::NeverCancel,
    )
    .map_err(|e| format!("{}", e))?;
    use std::io::Write;
    writer.flush().map_err(|e| format!("flush: {}", e))?;
    Ok(())
}
