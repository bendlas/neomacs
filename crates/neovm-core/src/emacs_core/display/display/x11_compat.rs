//! Real X11 wire-protocol queries backing the GNU-compatible `x-*` subrs.
//!
//! Neomacs's GUI is winit-based and usually identifies as `neo`, but a frame
//! backed by a real X11 connection can present as an `x` window system (see
//! `docs/exwm/milestone-0-architecture.md`).  EXWM and other X clients then
//! need real X server facts — the screen count, vendor/version strings, and
//! atom names — that the monitor-derived synthetic values cannot supply.
//!
//! This module owns one lazily-opened, thread-local X connection per display
//! name.  Only the evaluator thread calls these subrs, so a thread-local cache
//! is sufficient and avoids imposing `Send`/`Sync` on the connection.  The
//! connection is used for synchronous request/reply traffic only; it never
//! selects events, so it cannot steal the redirect or input masks that XELB and
//! winit own on their own connections.

/// A failure talking to an X server.
#[derive(Clone, Debug)]
pub(crate) enum X11Error {
    /// The display could not be opened.
    Connect(String),
    /// A request/reply failed after the connection was established.
    Protocol(String),
}

impl X11Error {
    /// Human-readable message in the shape GNU uses for X failures.
    pub(crate) fn message(&self) -> String {
        match self {
            Self::Connect(detail) => format!("X connection to {detail} broken"),
            Self::Protocol(detail) => format!("X protocol error: {detail}"),
        }
    }
}

/// Server-wide facts from the X connection setup reply.
#[derive(Clone, Debug)]
pub(crate) struct XServerInfo {
    pub screens: usize,
    pub vendor: String,
    /// `(protocol-major protocol-minor server-release)`.
    pub version: (u32, u32, u32),
}

#[cfg(target_os = "linux")]
mod imp {
    use super::{X11Error, XServerInfo};
    use std::cell::RefCell;
    use std::collections::HashMap;
    use std::rc::Rc;
    use x11rb::connection::Connection;
    use x11rb::errors::ReplyError;
    use x11rb::protocol::xproto::{Atom, ConnectionExt};
    use x11rb::rust_connection::RustConnection;

    thread_local! {
        /// Display name -> open connection.  `Rc` because `RustConnection`
        /// is single-owner and this cache is thread-confined.
        static CONNECTIONS: RefCell<HashMap<String, Rc<RustConnection>>> =
            RefCell::new(HashMap::new());
    }

    fn connection(display: &str) -> Result<Rc<RustConnection>, X11Error> {
        CONNECTIONS.with(|cache| {
            if let Some(existing) = cache.borrow().get(display) {
                return Ok(Rc::clone(existing));
            }
            let (conn, _screen) = RustConnection::connect(Some(display))
                .map_err(|error| X11Error::Connect(format!("{display}: {error}")))?;
            let conn = Rc::new(conn);
            cache
                .borrow_mut()
                .insert(display.to_owned(), Rc::clone(&conn));
            Ok(conn)
        })
    }

    fn protocol_error(error: impl std::fmt::Display) -> X11Error {
        X11Error::Protocol(error.to_string())
    }

    pub(crate) fn server_info(display: &str) -> Result<XServerInfo, X11Error> {
        let conn = connection(display)?;
        let setup = conn.setup();
        Ok(XServerInfo {
            screens: setup.roots.len(),
            vendor: String::from_utf8_lossy(&setup.vendor).into_owned(),
            version: (
                u32::from(setup.protocol_major_version),
                u32::from(setup.protocol_minor_version),
                setup.release_number,
            ),
        })
    }

    pub(crate) fn atom_name(display: &str, atom: u32) -> Result<Option<String>, X11Error> {
        let conn = connection(display)?;
        match conn
            .get_atom_name(atom as Atom)
            .map_err(protocol_error)?
            .reply()
        {
            Ok(reply) => Ok(Some(String::from_utf8_lossy(&reply.name).into_owned())),
            // GNU's `x-get-atom-name' answers nil for an atom the server does
            // not know; a BadAtom reply is that case, not a hard failure.
            Err(ReplyError::X11Error(_)) => Ok(None),
            Err(error) => Err(protocol_error(error)),
        }
    }

    /// The first screen's root geometry, in device pixels.
    pub(crate) fn screen_size(display: &str) -> Result<(i64, i64), X11Error> {
        let conn = connection(display)?;
        let Some(screen) = conn.setup().roots.first() else {
            return Err(X11Error::Protocol(
                "X server reports no screens".to_owned(),
            ));
        };
        Ok((
            i64::from(screen.width_in_pixels),
            i64::from(screen.height_in_pixels),
        ))
    }

    /// Move the X input focus to WINDOW, reverting to Parent on release.
    pub(crate) fn focus_window(display: &str, window: u32) -> Result<(), X11Error> {
        let conn = connection(display)?;
        // Fire-and-forget like GNU: focusing an unmapped (BadMatch) window must
        // not turn into a Lisp error, but a broken connection still surfaces on
        // flush.
        conn.set_input_focus(
            x11rb::protocol::xproto::InputFocus::PARENT,
            window,
            // X's CurrentTime (`XCB_CURRENT_TIME`).
            0u32,
        )
        .map_err(protocol_error)?;
        conn.flush().map_err(protocol_error)?;
        Ok(())
    }
}

#[cfg(not(target_os = "linux"))]
mod imp {
    use super::{X11Error, XServerInfo};

    fn unsupported() -> X11Error {
        X11Error::Connect("this platform".to_owned())
    }

    pub(crate) fn server_info(_display: &str) -> Result<XServerInfo, X11Error> {
        Err(unsupported())
    }

    pub(crate) fn atom_name(_display: &str, _atom: u32) -> Result<Option<String>, X11Error> {
        Err(unsupported())
    }

    pub(crate) fn screen_size(_display: &str) -> Result<(i64, i64), X11Error> {
        Err(unsupported())
    }

    pub(crate) fn focus_window(_display: &str, _window: u32) -> Result<(), X11Error> {
        Err(unsupported())
    }
}

pub(crate) use imp::{atom_name, focus_window, screen_size, server_info};
