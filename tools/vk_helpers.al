// ---- macros of vulkan_core.h (hand-written: tools/vk_helpers.al) ----

// VK_MAKE_API_VERSION(variant, major, minor, patch): a packed version number.
fn vk_make_api_version(variant: u32, major: u32, minor: u32, patch: u32) -> u32 {
    variant << 29 | major << 22 | minor << 12 | patch
}

// VK_API_VERSION_VARIANT(version)
fn vk_api_version_variant(version: u32) -> u32 { version >> 29 }

// VK_API_VERSION_MAJOR(version)
fn vk_api_version_major(version: u32) -> u32 { version >> 22 & 0x7F }

// VK_API_VERSION_MINOR(version)
fn vk_api_version_minor(version: u32) -> u32 { version >> 12 & 0x3FF }

// VK_API_VERSION_PATCH(version)
fn vk_api_version_patch(version: u32) -> u32 { version & 0xFFF }
