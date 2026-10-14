// Copyright 2026-Present Datadog, Inc. https://www.datadoghq.com/
// SPDX-License-Identifier: Apache-2.0

//! Remote configuration client for the .NET tracer.
//!
//! The tracer drives the polling: each [`ddog_rc_client_fetch`] call performs one request to the
//! agent, blocking the calling thread, and returns the configurations which changed since the
//! previous call. The contents of added or updated configurations are shared with the caller
//! without being copied: they stay valid until the caller passes their owner to
//! [`ddog_rc_content_drop`].

use function_name::named;
use libdd_capabilities_impl::{HttpClientCapability, NativeCapabilities};
use libdd_common::Endpoint;
use libdd_common_ffi::handle::{Handle, ToInner};
use libdd_common_ffi::slice::{AsBytes, CharSlice, Slice};
use libdd_common_ffi::{VoidResult, wrap_with_void_ffi_result};
use libdd_remote_config::fetch::{
    ConfigApplyState, ConfigInvariants, ConfigOptions, SingleFetcher,
};
use libdd_remote_config::file_change_tracker::{Change, ChangeTracker, FilePath, UpdatedFiles};
use libdd_remote_config::file_storage::{ParseFile, RawFile, RawFileStorage};
use libdd_remote_config::{
    RemoteConfigCapabilities, RemoteConfigPath, RemoteConfigProduct, Target,
};
use std::ffi::c_void;
use std::str::FromStr;
use std::sync::Arc;
use std::time::Duration;
use strum::IntoEnumIterator;
use tokio_util::sync::CancellationToken;

/// Stores the contents in an `Arc`, which is shared with the tracer when handing them out.
#[derive(Clone, Default)]
struct SharedBytesParser;

impl ParseFile for SharedBytesParser {
    type Parsed = Arc<Vec<u8>>;

    fn parse(&self, _path: &RemoteConfigPath, contents: Vec<u8>) -> Arc<Vec<u8>> {
        Arc::new(contents)
    }
}

type File = RawFile<Arc<Vec<u8>>>;
type Fetcher = SingleFetcher<RawFileStorage<SharedBytesParser>, NativeCapabilities>;

pub struct RcClient {
    runtime: tokio::runtime::Runtime,
    /// Only None while being replaced by a new instance, see [`RcClient::rebind`].
    fetcher: Option<Fetcher>,
    /// Tracks what was delivered to the tracer, so it outlives the fetcher instances.
    tracker: ChangeTracker<File>,
}

// The tracer uses a client from whichever thread polls, one at a time
const _: fn() = || {
    fn assert_send<T: Send>() {}
    assert_send::<RcClient>();
};

fn fetcher_lost() -> anyhow::Error {
    anyhow::anyhow!("The remote config client is unusable after a failed rebind")
}

#[repr(C)]
pub struct RcTarget<'a> {
    pub service: CharSlice<'a>,
    pub env: CharSlice<'a>,
    pub app_version: CharSlice<'a>,
    /// `key:value` formatted tags.
    pub tags: Slice<'a, CharSlice<'a>>,
    /// `key:value` formatted process tags.
    pub process_tags: Slice<'a, CharSlice<'a>>,
}

/// The products and capabilities are set with [`ddog_rc_client_set_products`].
#[repr(C)]
pub struct RcClientConfig<'a> {
    pub language: CharSlice<'a>,
    pub tracer_version: CharSlice<'a>,
    pub runtime_id: CharSlice<'a>,
    pub client_id: CharSlice<'a>,
    pub target: RcTarget<'a>,
}

pub const DDOG_RC_CHANGE_UPSERT: u32 = 0;
pub const DDOG_RC_CHANGE_REMOVE: u32 = 1;

#[repr(C)]
pub struct RcChange {
    /// The version of the config; 0 for removals.
    pub version: u64,
    /// The config path, e.g. `datadog/2/ASM_DD/blocking/config`. Valid until the changes are
    /// dropped.
    pub path_ptr: *const u8,
    pub path_len: usize,
    /// The contents of an added or updated config. Valid until passing `contents_owner` to
    /// [`ddog_rc_content_drop`], independently of the changes.
    pub contents_ptr: *const u8,
    pub contents_len: usize,
    /// Null for removals.
    pub contents_owner: *mut c_void,
    /// [`DDOG_RC_CHANGE_UPSERT`] or [`DDOG_RC_CHANGE_REMOVE`].
    pub kind: u32,
}

/// The removals come first, then the added or updated configs.
#[repr(C)]
pub struct RcChanges {
    pub ptr: *const RcChange,
    pub len: usize,
    /// Owns the changes and their paths, released by [`ddog_rc_changes_drop`].
    owner: *mut c_void,
}

struct ChangesBatch {
    changes: Vec<RcChange>,
    /// Keeps the paths alive.
    files: Vec<Arc<File>>,
}

impl ChangesBatch {
    fn push(&mut self, file: Arc<File>, upserted: bool) {
        let (kind, version, contents_ptr, contents_len, contents_owner) = if upserted {
            let contents = file.contents().clone();
            let (ptr, len) = (contents.as_ptr(), contents.len());
            let owner = Arc::into_raw(contents) as *mut c_void;
            (DDOG_RC_CHANGE_UPSERT, file.version(), ptr, len, owner)
        } else {
            (
                DDOG_RC_CHANGE_REMOVE,
                0,
                std::ptr::null(),
                0,
                std::ptr::null_mut(),
            )
        };
        let path = file.path().as_str();
        self.changes.push(RcChange {
            version,
            path_ptr: path.as_ptr(),
            path_len: path.len(),
            contents_ptr,
            contents_len,
            contents_owner,
            kind,
        });
        self.files.push(file);
    }

    fn into_ffi(self) -> RcChanges {
        let batch = Box::new(self);
        RcChanges {
            ptr: batch.changes.as_ptr(),
            len: batch.changes.len(),
            owner: Box::into_raw(batch) as *mut c_void,
        }
    }
}

fn to_string(slice: CharSlice) -> anyhow::Result<String> {
    Ok(slice.try_to_utf8()?.to_string())
}

fn to_strings(slices: Slice<CharSlice>) -> anyhow::Result<Vec<String>> {
    slices.iter().map(|s| to_string(*s)).collect()
}

fn to_target(target: &RcTarget) -> anyhow::Result<Target> {
    Ok(Target::new(
        to_string(target.service)?,
        to_string(target.env)?,
        to_string(target.app_version)?,
        to_strings(target.tags)?,
        to_strings(target.process_tags)?,
    ))
}

/// Unknown products are skipped, and reported as error once the known ones are applied.
fn to_products(
    products: Slice<CharSlice>,
) -> anyhow::Result<(Vec<RemoteConfigProduct>, Vec<String>)> {
    let mut known = vec![];
    let mut unknown = vec![];
    for product in products.iter() {
        let product = product.try_to_utf8()?;
        match RemoteConfigProduct::from_str(product) {
            Ok(product) => known.push(product),
            Err(_) => unknown.push(product.to_string()),
        }
    }
    Ok((known, unknown))
}

fn to_capabilities(capabilities: u64) -> Vec<RemoteConfigCapabilities> {
    RemoteConfigCapabilities::iter()
        .filter(|c| (*c as u32) < 64 && capabilities & (1 << (*c as u32)) != 0)
        .collect()
}

fn report_unknown_products(unknown: Vec<String>) -> anyhow::Result<()> {
    if unknown.is_empty() {
        Ok(())
    } else {
        anyhow::bail!("Unsupported remote config products: {}", unknown.join(", "))
    }
}

impl RcClient {
    fn new(config: &RcClientConfig, endpoint: &Endpoint) -> anyhow::Result<RcClient> {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            // Only needed for DNS resolution.
            .max_blocking_threads(1)
            .thread_keep_alive(Duration::from_secs(1))
            .build()?;
        let fetcher = SingleFetcher::new_no_agentless(
            RawFileStorage::default(),
            to_target(&config.target)?,
            to_string(config.runtime_id)?,
            ConfigOptions {
                invariants: ConfigInvariants {
                    language: to_string(config.language)?,
                    tracer_version: to_string(config.tracer_version)?,
                    endpoint: endpoint.clone(),
                    agentless: None,
                },
                products: vec![],
                capabilities: vec![],
            },
            NativeCapabilities::new_periodic(),
        )
        .with_client_id(to_string(config.client_id)?);
        Ok(RcClient {
            runtime,
            fetcher: Some(fetcher),
            tracker: ChangeTracker::default(),
        })
    }

    fn fetcher(&mut self) -> anyhow::Result<&mut Fetcher> {
        self.fetcher.as_mut().ok_or_else(fetcher_lost)
    }

    /// Replaces the fetcher with a new instance for `target` and `endpoint` (if any, otherwise the
    /// current one), which takes over the known files of the previous one.
    fn rebind(&mut self, target: Target, endpoint: Option<Endpoint>) -> anyhow::Result<()> {
        let previous = self.fetcher.take().ok_or_else(fetcher_lost)?;
        self.fetcher = Some(self.runtime.block_on(previous.rebind(target, endpoint))?);
        Ok(())
    }

    fn fetch(&mut self, cancel: Option<&CancellationToken>) -> anyhow::Result<ChangesBatch> {
        let RcClient {
            runtime,
            fetcher,
            tracker,
        } = self;
        let fetcher = fetcher.as_mut().ok_or_else(fetcher_lost)?;
        let files = runtime.block_on(async {
            match cancel {
                Some(cancel) => tokio::select! {
                    biased;
                    _ = cancel.cancelled() => anyhow::bail!("The remote config fetch was cancelled"),
                    files = fetcher.fetch_once() => files,
                },
                None => fetcher.fetch_once().await,
            }
        })?;

        let mut batch = ChangesBatch {
            changes: vec![],
            files: vec![],
        };
        let Some(files) = files else {
            return Ok(batch);
        };
        let updated = fetcher.file_storage().updated();
        for change in tracker.get_changes(files, updated) {
            match change {
                Change::Remove(file) => batch.push(file, false),
                Change::Add(file) | Change::Update(file, _) => {
                    fetcher.set_config_state(file.path(), ConfigApplyState::Unacknowledged);
                    batch.push(file, true);
                }
            }
        }
        Ok(batch)
    }
}

/// Creates a remote config client for the agent at `endpoint` (see `ddog_endpoint_from_url`),
/// which is copied. The client does nothing until [`ddog_rc_client_fetch`] is called.
///
/// # Safety
/// All slices in `config` must be valid.
#[unsafe(no_mangle)]
#[must_use]
#[named]
pub unsafe extern "C" fn ddog_rc_client_new(
    config: &RcClientConfig,
    endpoint: &Endpoint,
    out_client: &mut *mut RcClient,
) -> VoidResult {
    wrap_with_void_ffi_result!({
        *out_client = Box::into_raw(Box::new(RcClient::new(config, endpoint)?));
    })
}

/// # Safety
/// `client` must be null or come from [`ddog_rc_client_new`], and not be in use by any other
/// thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ddog_rc_client_drop(client: *mut RcClient) {
    if !client.is_null() {
        drop(unsafe { Box::from_raw(client) });
    }
}

/// Switches to another target (service, env, version, tags) and, if `endpoint` is not null,
/// another agent endpoint (which is copied), with a new fetcher instance (and client session)
/// taking over the known files. Unchanged files are neither downloaded again nor reported as
/// changed.
///
/// # Safety
/// All slices must be valid.
#[unsafe(no_mangle)]
#[must_use]
#[named]
pub unsafe extern "C" fn ddog_rc_client_rebind(
    client: &mut RcClient,
    target: &RcTarget,
    endpoint: Option<&Endpoint>,
) -> VoidResult {
    wrap_with_void_ffi_result!({
        client.rebind(to_target(target)?, endpoint.cloned())?;
    })
}

/// Replaces the subscribed products (names like `ASM_DD`) and the capabilities (bit n set for the
/// capability with index n). Unsupported products are reported as error, after applying the
/// supported ones.
///
/// # Safety
/// All slices must be valid.
#[unsafe(no_mangle)]
#[must_use]
#[named]
pub unsafe extern "C" fn ddog_rc_client_set_products(
    client: &mut RcClient,
    products: Slice<CharSlice>,
    capabilities: u64,
) -> VoidResult {
    wrap_with_void_ffi_result!({
        let (products, unknown) = to_products(products)?;
        client
            .fetcher()?
            .set_product_capabilities(products, to_capabilities(capabilities));
        report_unknown_products(unknown)?;
    })
}

/// Replaces the services discovered at runtime, which are sent to the agent with each request.
///
/// # Safety
/// All slices must be valid.
#[unsafe(no_mangle)]
#[must_use]
#[named]
pub unsafe extern "C" fn ddog_rc_client_set_extra_services(
    client: &mut RcClient,
    services: Slice<CharSlice>,
) -> VoidResult {
    wrap_with_void_ffi_result!({
        let services = to_strings(services)?;
        client.fetcher()?.set_extra_services(services);
    })
}

/// Polls the agent once, blocking until the response is processed, the request timed out, or
/// `cancel` is cancelled. To cancel from another thread, e.g. on shutdown, pass a token from
/// `ddog_CancellationToken_new` here and cancel a clone of it (`ddog_CancellationToken_clone`).
/// On success, `out_changes` must be released with [`ddog_rc_changes_drop`].
///
/// # Safety
/// `cancel` must be null or a valid token.
#[unsafe(no_mangle)]
#[must_use]
#[named]
pub unsafe extern "C" fn ddog_rc_client_fetch(
    client: &mut RcClient,
    mut cancel: *mut Handle<CancellationToken>,
    out_changes: &mut RcChanges,
) -> VoidResult {
    wrap_with_void_ffi_result!({
        let cancel = unsafe { cancel.to_inner_mut() }.ok();
        *out_changes = client.fetch(cancel.as_deref())?.into_ffi();
    })
}

/// Sets the apply state reported for a config: 1 = unacknowledged, 2 = acknowledged, 3 = error
/// (with `error` as message).
///
/// # Safety
/// All slices must be valid.
#[unsafe(no_mangle)]
#[must_use]
#[named]
pub unsafe extern "C" fn ddog_rc_client_set_apply_state(
    client: &mut RcClient,
    path: CharSlice,
    state: u32,
    error: CharSlice,
) -> VoidResult {
    wrap_with_void_ffi_result!({
        let path = RemoteConfigPath::parse(path.try_to_utf8()?)?;
        let state = match state {
            1 => ConfigApplyState::Unacknowledged,
            2 => ConfigApplyState::Acknowledged,
            3 => ConfigApplyState::Error(to_string(error)?),
            _ => anyhow::bail!("Invalid apply state {state}"),
        };
        client.fetcher()?.set_config_state(&path, state);
    })
}

/// Releases the changes, but not the contents of the configs, see [`ddog_rc_content_drop`].
///
/// # Safety
/// `changes` must come from [`ddog_rc_client_fetch`] and must not be used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ddog_rc_changes_drop(changes: RcChanges) {
    if !changes.owner.is_null() {
        drop(unsafe { Box::from_raw(changes.owner as *mut ChangesBatch) });
    }
}

/// Releases the contents of a config.
///
/// # Safety
/// `owner` must be null or the `contents_owner` of a change, and must not be used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ddog_rc_content_drop(owner: *mut c_void) {
    if !owner.is_null() {
        drop(unsafe { Arc::from_raw(owner as *const Vec<u8>) });
    }
}

impl Default for RcChanges {
    fn default() -> Self {
        RcChanges {
            ptr: std::ptr::null(),
            len: 0,
            owner: std::ptr::null_mut(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use libdd_common_ffi::endpoint::ddog_endpoint_from_url;
    use libdd_remote_config::fetch::test_server::RemoteConfigServer;

    fn slices(strings: &[&'static str]) -> Vec<CharSlice<'static>> {
        strings.iter().map(|s| CharSlice::from(*s)).collect()
    }

    struct Fixture {
        server: Arc<RemoteConfigServer>,
        _server_runtime: tokio::runtime::Runtime,
        client: *mut RcClient,
        tags: Vec<CharSlice<'static>>,
    }

    impl Fixture {
        fn new() -> Fixture {
            let server_runtime = tokio::runtime::Runtime::new().unwrap();
            let server = server_runtime.block_on(async { RemoteConfigServer::spawn() });
            Fixture {
                server,
                _server_runtime: server_runtime,
                client: std::ptr::null_mut(),
                tags: slices(&["key:value"]),
            }
        }

        fn target(&self, service: &'static str) -> RcTarget<'_> {
            RcTarget {
                service: service.into(),
                env: "env".into(),
                app_version: "1.2.3".into(),
                tags: Slice::new(&self.tags),
                process_tags: Slice::empty(),
            }
        }

        fn create(&mut self, url: &str) -> VoidResult {
            let mut client = std::ptr::null_mut();
            let endpoint = ddog_endpoint_from_url(CharSlice::from(url)).unwrap();
            let config = RcClientConfig {
                language: "dotnet".into(),
                tracer_version: "3.0.0".into(),
                runtime_id: "runtime-id".into(),
                client_id: "client-id".into(),
                target: self.target("first"),
            };
            let result = unsafe { ddog_rc_client_new(&config, &endpoint, &mut client) };
            self.client = client;
            result
        }

        fn set_products(&self, products: &[&'static str]) -> VoidResult {
            let products = slices(products);
            unsafe {
                ddog_rc_client_set_products(
                    self.client(),
                    Slice::new(&products),
                    1 << RemoteConfigCapabilities::ApmTracingCustomTags as u32,
                )
            }
        }

        /// Creates the client, subscribed to APM_TRACING.
        fn start(&mut self) {
            let url = self.server.endpoint.url.to_string();
            self.create(&url).unwrap();
            self.set_products(&["APM_TRACING"]).unwrap();
        }

        // The tests only use one reference at a time
        #[allow(clippy::mut_from_ref)]
        fn client(&self) -> &mut RcClient {
            unsafe { &mut *self.client }
        }

        fn add_file(&self, id: &str, services: &[&str], contents: &str) {
            let targets = services
                .iter()
                .map(|s| {
                    Arc::new(Target::new(
                        s.to_string(),
                        "env".to_string(),
                        "1.2.3".to_string(),
                        vec![],
                        vec![],
                    ))
                })
                .collect();
            self.server.files.lock().unwrap().insert(
                RemoteConfigPath::parse(&format!("datadog/2/APM_TRACING/{id}/config")).unwrap(),
                (targets, 1, contents.to_string()),
            );
        }

        /// Returns (kind, path, contents) and releases everything.
        fn fetch(&self) -> Vec<(u32, String, Option<String>)> {
            let mut changes = RcChanges::default();
            unsafe { ddog_rc_client_fetch(self.client(), std::ptr::null_mut(), &mut changes) }
                .unwrap();
            let result = unsafe { std::slice::from_raw_parts(changes.ptr, changes.len) }
                .iter()
                .map(|c| unsafe {
                    let path =
                        std::str::from_utf8(std::slice::from_raw_parts(c.path_ptr, c.path_len))
                            .unwrap()
                            .to_string();
                    let contents = (!c.contents_owner.is_null()).then(|| {
                        String::from_utf8(
                            std::slice::from_raw_parts(c.contents_ptr, c.contents_len).to_vec(),
                        )
                        .unwrap()
                    });
                    (c.kind, path, contents, c.contents_owner)
                })
                .collect::<Vec<_>>();
            unsafe { ddog_rc_changes_drop(changes) };
            result
                .into_iter()
                .map(|(kind, path, contents, owner)| {
                    unsafe { ddog_rc_content_drop(owner) };
                    (kind, path, contents)
                })
                .collect()
        }

        fn last_request_state(&self) -> RequestState {
            let request = self.server.last_request.lock().unwrap();
            let client = request.as_ref().unwrap().client.as_ref().unwrap();
            let state = client.state.as_ref().unwrap();
            RequestState {
                service: client.client_tracer.as_ref().unwrap().service.clone(),
                targets_version: state.targets_version,
                config_states: state
                    .config_states
                    .iter()
                    .map(|s| (s.id.clone(), s.apply_state, s.apply_error.clone()))
                    .collect(),
                cached_files: request.as_ref().unwrap().cached_target_files.len(),
            }
        }
    }

    struct RequestState {
        service: String,
        targets_version: u64,
        config_states: Vec<(String, u64, String)>,
        cached_files: usize,
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            unsafe { ddog_rc_client_drop(self.client) };
        }
    }

    const UPSERT: u32 = DDOG_RC_CHANGE_UPSERT;
    const REMOVE: u32 = DDOG_RC_CHANGE_REMOVE;

    fn path(id: &str) -> String {
        format!("datadog/2/APM_TRACING/{id}/config")
    }

    #[test]
    #[cfg_attr(miri, ignore)]
    fn subscribes_to_known_products_and_reports_unknown_ones() {
        let mut fixture = Fixture::new();
        fixture.start();
        assert!(matches!(
            fixture.set_products(&["NOT_A_PRODUCT", "ASM_DD"]),
            VoidResult::Err(_)
        ));
        fixture.fetch();
        let request = fixture.server.last_request.lock().unwrap();
        let client = request.as_ref().unwrap().client.as_ref().unwrap();
        assert_eq!(client.products, ["ASM_DD"]);
        // Capability 15, big endian
        assert_eq!(client.capabilities, [0x80, 0x00]);
    }

    #[test]
    #[cfg_attr(miri, ignore)]
    fn delivers_changes_and_apply_states() {
        let mut fixture = Fixture::new();
        fixture.start();

        fixture.add_file("a", &["first"], "{\"a\":1}");
        fixture.add_file("b", &["first"], "{\"b\":1}");
        let mut changes = fixture.fetch();
        changes.sort();
        assert_eq!(
            changes,
            [
                (UPSERT, path("a"), Some("{\"a\":1}".to_string())),
                (UPSERT, path("b"), Some("{\"b\":1}".to_string())),
            ]
        );

        unsafe {
            ddog_rc_client_set_apply_state(
                fixture.client(),
                path("a").as_str().into(),
                2,
                CharSlice::empty(),
            )
            .unwrap();
            ddog_rc_client_set_apply_state(
                fixture.client(),
                path("b").as_str().into(),
                3,
                "broken".into(),
            )
            .unwrap();
        }

        fixture
            .server
            .files
            .lock()
            .unwrap()
            .remove(&RemoteConfigPath::parse(&path("a")).unwrap());
        fixture.add_file("b", &["first"], "{\"b\":2}");
        assert_eq!(
            fixture.fetch(),
            [
                (REMOVE, path("a"), None),
                (UPSERT, path("b"), Some("{\"b\":2}".to_string())),
            ]
        );
        let mut states = fixture.last_request_state().config_states;
        states.sort();
        assert_eq!(
            states,
            [
                ("a".to_string(), 2, String::new()),
                ("b".to_string(), 3, "broken".to_string())
            ]
        );

        // Nothing changed
        assert_eq!(fixture.fetch(), []);
        assert_eq!(
            fixture.last_request_state().config_states,
            [("b".to_string(), 1, String::new())]
        );
    }

    #[test]
    #[cfg_attr(miri, ignore)]
    fn rebind_reports_only_differences() {
        let mut fixture = Fixture::new();
        fixture.start();

        fixture.add_file("only_first", &["first"], "1");
        fixture.add_file("shared", &["first", "second"], "2");
        fixture.add_file("only_second", &["second"], "3");
        assert_eq!(fixture.fetch().len(), 2);

        let url = fixture.server.endpoint.url.to_string();
        let target = fixture.target("second");
        let endpoint = ddog_endpoint_from_url(url.as_str().into()).unwrap();
        unsafe { ddog_rc_client_rebind(fixture.client(), &target, Some(&endpoint)) }.unwrap();
        assert_eq!(
            fixture.fetch(),
            [
                (REMOVE, path("only_first"), None),
                (UPSERT, path("only_second"), Some("3".to_string())),
            ]
        );
        let state = fixture.last_request_state();
        assert_eq!(state.service, "second");
        assert_eq!(state.targets_version, 0);
        assert_eq!(state.cached_files, 2);
    }

    #[test]
    #[cfg_attr(miri, ignore)]
    fn contents_outlive_the_client() {
        let mut fixture = Fixture::new();
        fixture.start();
        fixture.add_file("a", &["first"], "contents");

        let mut changes = RcChanges::default();
        unsafe { ddog_rc_client_fetch(fixture.client(), std::ptr::null_mut(), &mut changes) }
            .unwrap();
        let change = unsafe { &*changes.ptr };
        let (ptr, len, owner) = (
            change.contents_ptr,
            change.contents_len,
            change.contents_owner,
        );
        unsafe {
            ddog_rc_changes_drop(changes);
            ddog_rc_client_drop(fixture.client);
        }
        fixture.client = std::ptr::null_mut();
        assert_eq!(unsafe { std::slice::from_raw_parts(ptr, len) }, b"contents");
        unsafe { ddog_rc_content_drop(owner) };
    }

    #[test]
    #[cfg_attr(miri, ignore)]
    fn cancelled_fetch_fails_fast() {
        let mut fixture = Fixture::new();
        // Nothing listens there: the fetch would otherwise fail by itself
        fixture.create("http://127.0.0.1:1").unwrap();
        let token = CancellationToken::new();
        token.cancel();
        let mut handle: Handle<CancellationToken> = token.into();
        let mut changes = RcChanges::default();
        let VoidResult::Err(err) =
            (unsafe { ddog_rc_client_fetch(fixture.client(), &mut handle, &mut changes) })
        else {
            panic!("expected an error");
        };
        assert!(err.as_ref().contains("cancelled"), "{}", err.as_ref());
        drop(unsafe { handle.take() });
    }

    #[test]
    #[cfg_attr(miri, ignore)]
    fn cancel_aborts_an_ongoing_fetch() {
        let mut fixture = Fixture::new();
        // Accepts connections (in its backlog), but never responds
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/", listener.local_addr().unwrap());
        fixture.create(&url).unwrap();
        let token = CancellationToken::new();
        let clone = token.clone();
        let canceller = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(200));
            clone.cancel();
        });
        let mut handle: Handle<CancellationToken> = token.into();
        let mut changes = RcChanges::default();
        let VoidResult::Err(err) =
            (unsafe { ddog_rc_client_fetch(fixture.client(), &mut handle, &mut changes) })
        else {
            panic!("expected an error");
        };
        assert!(err.as_ref().contains("cancelled"), "{}", err.as_ref());
        canceller.join().unwrap();
        drop(unsafe { handle.take() });
    }
}
