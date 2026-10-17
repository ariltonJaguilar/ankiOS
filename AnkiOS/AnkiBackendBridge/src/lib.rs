use anki::backend::Backend;
use anki::prelude::I18n;
use anki::services::{BackendCollectionService, BackendSyncService};
use anki_proto::collection::{CloseCollectionRequest, OpenCollectionRequest};
use anki_proto::sync::{
    FullUploadOrDownloadRequest, SyncAuth, SyncCollectionRequest, SyncLoginRequest,
};
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

pub struct AnkiSyncBackend {
    backend: Backend,
    collection_open: bool,
}

unsafe fn read_string(value: *const c_char, name: &str) -> Result<String, String> {
    if value.is_null() {
        return Err(format!("{name} is missing"));
    }
    CStr::from_ptr(value)
        .to_str()
        .map(str::to_owned)
        .map_err(|error| error.to_string())
}

unsafe fn read_optional_string(value: *const c_char) -> Result<Option<String>, String> {
    if value.is_null() {
        return Ok(None);
    }
    let value = CStr::from_ptr(value)
        .to_str()
        .map_err(|error| error.to_string())?;
    if value.is_empty() {
        Ok(None)
    } else {
        Ok(Some(value.to_owned()))
    }
}

fn into_c_string(value: String) -> *mut c_char {
    CString::new(value.replace('\0', ""))
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

unsafe fn set_error(error_out: *mut *mut c_char, error: String) {
    if !error_out.is_null() {
        *error_out = into_c_string(error);
    }
}

unsafe fn reset_error(error_out: *mut *mut c_char) {
    if !error_out.is_null() {
        *error_out = std::ptr::null_mut();
    }
}

fn run_json<F>(error_out: *mut *mut c_char, operation: F) -> *mut c_char
where
    F: FnOnce() -> Result<Value, String>,
{
    unsafe { reset_error(error_out) };
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(Ok(value)) => into_c_string(value.to_string()),
        Ok(Err(error)) => {
            unsafe { set_error(error_out, error) };
            std::ptr::null_mut()
        }
        Err(_) => {
            unsafe { set_error(error_out, "Anki backend panic".to_owned()) };
            std::ptr::null_mut()
        }
    }
}

fn auth(hkey: String, endpoint: Option<String>) -> SyncAuth {
    SyncAuth {
        hkey,
        endpoint,
        io_timeout_secs: None,
    }
}

#[no_mangle]
pub unsafe extern "C" fn ankios_anki_extract_latex(
    text: *const c_char,
    svg: i32,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    reset_error(error_out);
    let result = catch_unwind(AssertUnwindSafe(|| {
        let text = read_string(text, "latex text")?;
        let (rendered, _) = anki::latex::extract_latex(&text, svg != 0);
        Ok::<_, String>(into_c_string(rendered.into_owned()))
    }));
    match result {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => {
            set_error(error_out, error);
            std::ptr::null_mut()
        }
        Err(_) => {
            set_error(error_out, "Anki LaTeX extraction failed".to_owned());
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn ankios_anki_extract_latex_details(
    text: *const c_char,
    svg: i32,
    expand_clozes: i32,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    run_json(error_out, || {
        let text = read_string(text, "latex text")?;
        let expanded;
        let source = if expand_clozes != 0 && text.contains("{{c") {
            expanded = anki::cloze::expand_clozes_to_reveal_latex(&text);
            expanded.as_str()
        } else {
            text.as_str()
        };
        let (rendered, extracted) = anki::latex::extract_latex(source, svg != 0);
        let latex = extracted
            .into_iter()
            .map(|item| json!({"filename": item.fname, "body": item.latex}))
            .collect::<Vec<_>>();
        Ok(json!({"html": rendered, "latex": latex}))
    })
}

#[no_mangle]
pub unsafe extern "C" fn ankios_anki_backend_open(
    collection_path: *const c_char,
    media_folder_path: *const c_char,
    media_db_path: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut AnkiSyncBackend {
    reset_error(error_out);
    let result = catch_unwind(AssertUnwindSafe(|| {
        let collection_path = read_string(collection_path, "collection path")?;
        let media_folder_path = read_string(media_folder_path, "media folder path")?;
        let media_db_path = read_string(media_db_path, "media database path")?;
        let backend = Backend::new(I18n::new(&["en"]), false);
        backend
            .open_collection(OpenCollectionRequest {
                collection_path,
                media_folder_path,
                media_db_path,
            })
            .map_err(|error| error.to_string())?;
        Ok::<_, String>(AnkiSyncBackend {
            backend,
            collection_open: true,
        })
    }));
    match result {
        Ok(Ok(handle)) => Box::into_raw(Box::new(handle)),
        Ok(Err(error)) => {
            set_error(error_out, error);
            std::ptr::null_mut()
        }
        Err(_) => {
            set_error(error_out, "Anki backend panic".to_owned());
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn ankios_anki_sync_login(
    handle: *mut AnkiSyncBackend,
    username: *const c_char,
    password: *const c_char,
    endpoint: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    run_json(error_out, || {
        let handle = handle.as_ref().ok_or_else(|| "backend is missing".to_owned())?;
        let username = read_string(username, "username")?;
        let password = read_string(password, "password")?;
        let endpoint = read_optional_string(endpoint)?;
        let response = handle
            .backend
            .sync_login(SyncLoginRequest {
                username,
                password,
                endpoint,
            })
            .map_err(|error| error.to_string())?;
        Ok(json!({"hkey": response.hkey, "endpoint": response.endpoint}))
    })
}

#[no_mangle]
pub unsafe extern "C" fn ankios_anki_sync_status(
    handle: *mut AnkiSyncBackend,
    hkey: *const c_char,
    endpoint: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    run_json(error_out, || {
        let handle = handle.as_ref().ok_or_else(|| "backend is missing".to_owned())?;
        let response = handle
            .backend
            .sync_status(auth(
                read_string(hkey, "sync key")?,
                read_optional_string(endpoint)?,
            ))
            .map_err(|error| error.to_string())?;
        Ok(json!({"required": response.required as i32, "newEndpoint": response.new_endpoint}))
    })
}

#[no_mangle]
pub unsafe extern "C" fn ankios_anki_sync_collection(
    handle: *mut AnkiSyncBackend,
    hkey: *const c_char,
    endpoint: *const c_char,
    sync_media: i32,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    run_json(error_out, || {
        let handle = handle.as_ref().ok_or_else(|| "backend is missing".to_owned())?;
        let response = handle
            .backend
            .sync_collection(SyncCollectionRequest {
                auth: Some(auth(
                    read_string(hkey, "sync key")?,
                    read_optional_string(endpoint)?,
                )),
                sync_media: sync_media != 0,
            })
            .map_err(|error| error.to_string())?;
        Ok(json!({
            "hostNumber": response.host_number,
            "serverMessage": response.server_message,
            "required": response.required,
            "newEndpoint": response.new_endpoint,
            "serverMediaUsn": response.server_media_usn
        }))
    })
}

#[no_mangle]
pub unsafe extern "C" fn ankios_anki_sync_full_upload_or_download(
    handle: *mut AnkiSyncBackend,
    hkey: *const c_char,
    endpoint: *const c_char,
    upload: i32,
    has_server_usn: i32,
    server_usn: i32,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    run_json(error_out, || {
        let handle = handle.as_ref().ok_or_else(|| "backend is missing".to_owned())?;
        handle
            .backend
            .full_upload_or_download(FullUploadOrDownloadRequest {
                auth: Some(auth(
                    read_string(hkey, "sync key")?,
                    read_optional_string(endpoint)?,
                )),
                upload: upload != 0,
                server_usn: (has_server_usn != 0).then_some(server_usn),
            })
            .map_err(|error| error.to_string())?;
        Ok(json!({"complete": true}))
    })
}

#[no_mangle]
pub unsafe extern "C" fn ankios_anki_media_sync_status(
    handle: *mut AnkiSyncBackend,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    run_json(error_out, || {
        let handle = handle.as_ref().ok_or_else(|| "backend is missing".to_owned())?;
        let response = handle
            .backend
            .media_sync_status()
            .map_err(|error| error.to_string())?;
        let progress = response.progress.map(|progress| {
            json!({
                "checked": progress.checked,
                "added": progress.added,
                "removed": progress.removed
            })
        });
        Ok(json!({"active": response.active, "progress": progress}))
    })
}

#[no_mangle]
pub unsafe extern "C" fn ankios_anki_sync_media(
    handle: *mut AnkiSyncBackend,
    hkey: *const c_char,
    endpoint: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    run_json(error_out, || {
        let handle = handle.as_ref().ok_or_else(|| "backend is missing".to_owned())?;
        handle
            .backend
            .sync_media(auth(
                read_string(hkey, "sync key")?,
                read_optional_string(endpoint)?,
            ))
            .map_err(|error| error.to_string())?;
        Ok(json!({"started": true}))
    })
}

#[no_mangle]
pub unsafe extern "C" fn ankios_anki_sync_abort(
    handle: *mut AnkiSyncBackend,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    run_json(error_out, || {
        let handle = handle.as_ref().ok_or_else(|| "backend is missing".to_owned())?;
        handle
            .backend
            .abort_sync()
            .map_err(|error| error.to_string())?;
        Ok(json!({"aborted": true}))
    })
}

#[no_mangle]
pub unsafe extern "C" fn ankios_anki_media_sync_abort(
    handle: *mut AnkiSyncBackend,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    run_json(error_out, || {
        let handle = handle.as_ref().ok_or_else(|| "backend is missing".to_owned())?;
        handle
            .backend
            .abort_media_sync()
            .map_err(|error| error.to_string())?;
        Ok(json!({"aborted": true}))
    })
}

#[no_mangle]
pub unsafe extern "C" fn ankios_anki_backend_close(
    handle: *mut AnkiSyncBackend,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    run_json(error_out, || {
        let handle = handle.as_mut().ok_or_else(|| "backend is missing".to_owned())?;
        if handle.collection_open {
            handle
                .backend
                .close_collection(CloseCollectionRequest {
                    downgrade_to_schema11: true,
                })
                .map_err(|error| error.to_string())?;
            handle.collection_open = false;
        }
        Ok(json!({"closed": true, "schema": 11}))
    })
}

#[no_mangle]
pub unsafe extern "C" fn ankios_anki_backend_destroy(handle: *mut AnkiSyncBackend) {
    if handle.is_null() {
        return;
    }
    let mut handle = Box::from_raw(handle);
    if handle.collection_open {
        let _ = handle.backend.close_collection(CloseCollectionRequest {
            downgrade_to_schema11: true,
        });
        handle.collection_open = false;
    }
}

#[no_mangle]
pub unsafe extern "C" fn ankios_anki_backend_free_string(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

mod fsrs_bridge {
    include!("../../FSRSBridge/lib.rs");
}
