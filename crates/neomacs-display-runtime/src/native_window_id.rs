//! Native window-id extraction for GUI frames.
//!
//! GNU Emacs exposes the X window ids of a frame as the `window-id` and
//! `outer-window-id` frame parameters, and X clients reparent and reference
//! them directly.  winit owns the top-level window, so read its raw handle
//! here.  With no window manager having reparented the winit top level yet,
//! the frame's own window and its outer container are the same XID.

use winit::window::Window;

/// Return `(window-id, outer-window-id)` for a window winit realized on X11.
///
/// `None` on every other backend (Wayland, Cocoa, Windows) and when winit has
/// not yet created a native handle.
#[cfg(target_os = "linux")]
pub fn x11_window_ids(window: &dyn Window) -> Option<(u64, u64)> {
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};
    match window.window_handle().ok()?.as_raw() {
        RawWindowHandle::Xlib(handle) => {
            let id = handle.window as u64;
            Some((id, id))
        }
        RawWindowHandle::Xcb(handle) => {
            let id = handle.window.get() as u64;
            Some((id, id))
        }
        _ => None,
    }
}

/// Non-Linux builds have no X11 window handle to report.
#[cfg(not(target_os = "linux"))]
pub fn x11_window_ids(_window: &dyn Window) -> Option<(u64, u64)> {
    None
}
