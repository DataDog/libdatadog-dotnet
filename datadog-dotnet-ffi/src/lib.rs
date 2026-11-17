// Copyright 2026-Present Datadog, Inc. https://www.datadoghq.com/
// SPDX-License-Identifier: Apache-2.0

#![cfg_attr(not(test), deny(clippy::panic))]
#![cfg_attr(not(test), deny(clippy::unwrap_used))]
#![cfg_attr(not(test), deny(clippy::expect_used))]

// Re-export the whole profiling library (profiling, crashtracker, symbolizer, library-config),
// so that this library is a drop-in replacement for it.
pub use datadog_profiling_ffi::*;

pub mod remote_config;
