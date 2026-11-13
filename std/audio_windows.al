// std.audio, Windows layer: the output device through WASAPI in shared mode (ole32.dll for
// COM, the audio engine through mmdevapi). Loaded by `use std.audio` for --target windows; the
// shared part is std/audio.al.
//
// - The device: IMMDeviceEnumerator gives the default render endpoint (role eConsole) or one
//   chosen by name; its IAudioClient is initialised in shared mode with the engine's mix format
//   exactly as GetMixFormat returns it (always accepted, no conversion inside Windows), event
//   driven, with a buffer of `latency_ms`.
// - Conversion: the mixer runs at the rate and channel count the program opened. Its frames go
//   through a small queue (AudioOs.q) into a linear-interpolation resampler (32.32 fixed point,
//   like the mixer's pitch) when the device rate differs, are mapped to the device's channels
//   (mono is copied to the first two channels, stereo goes to front left / right and further
//   channels stay silent, a mono device gets the average) and are stored in the mix format's
//   sample type (32-bit float, or 16 / 24 / 32-bit integers).
// - Writing: audio_pump asks GetCurrentPadding how much of the buffer is free and fills exactly
//   that, without waiting; audio_write waits on the stream's event (signalled by the engine every
//   period) while the buffer is full. There is no audio thread (see docs/std/audio.md).
// - Device loss (AUDCLNT_E_DEVICE_INVALIDATED and any other failing call): the stream is
//   released and `lost` set; audio_pump / audio_write open the device again (by the same name;
//   "default" finds the current default device) at most every 500 ms. A device opened as
//   "default" also follows changes of the default device (checked once a second).

priv extern "ole32.dll" fn CoInitializeEx(reserved: *u8, coinit: u32) -> i32
priv extern "ole32.dll" fn CoUninitialize()
priv extern "ole32.dll" fn CoCreateInstance(clsid: *GUID, outer: *u8, context: u32, iid: *GUID, object: **u8) -> i32
priv extern "ole32.dll" fn CoTaskMemFree(p: *u8)
priv extern "ole32.dll" fn PropVariantClear(value: *PROPVARIANT) -> i32
priv extern "kernel32.dll" fn CreateEventW(attributes: *u8, manual_reset: i32, initial_state: i32, name: *u16) -> *u8
priv extern "kernel32.dll" fn WaitForSingleObject(handle: *u8, milliseconds: u32) -> u32
priv extern "kernel32.dll" fn CloseHandle(handle: *u8) -> i32
priv extern "kernel32.dll" fn Sleep(milliseconds: u32)
priv extern "kernel32.dll" fn GetTickCount64() -> u64

priv const COINIT_APARTMENTTHREADED: u32 = 0x2
priv const COINIT_DISABLE_OLE1DDE: u32 = 0x4
priv const CLSCTX_ALL: u32 = 0x17
priv const RPC_E_CHANGED_MODE: i32 = 0x80010106
priv const E_NOTFOUND: i32 = 0x80070490
priv const AUDCLNT_E_DEVICE_INVALIDATED: i32 = 0x88890004
priv const eRender: i32 = 0
priv const eConsole: i32 = 0
priv const DEVICE_STATE_ACTIVE: u32 = 0x1
priv const STGM_READ: u32 = 0
priv const VT_LPWSTR: u16 = 31
priv const AUDCLNT_SHAREMODE_SHARED: i32 = 0
priv const AUDCLNT_STREAMFLAGS_EVENTCALLBACK: u32 = 0x40000
priv const WAVE_FORMAT_PCM: u16 = 1
priv const WAVE_FORMAT_IEEE_FLOAT: u16 = 3
priv const WAVE_FORMAT_EXTENSIBLE: u16 = 0xFFFE

// sample types of the mix format (AudioOs.kind)
priv const WA_F32 = 0
priv const WA_I16 = 1
priv const WA_I24 = 2
priv const WA_I32 = 3

// how often a lost device is looked for again, and how often "default" checks for a new default
priv const WA_RETRY_MS: u64 = 500
priv const WA_DEFAULT_CHECK_MS: u64 = 1000

priv struct GUID {
    Data1: u32
    Data2: u16
    Data3: u16
    Data4: [8]u8
}

priv struct PROPERTYKEY {
    fmtid: GUID
    pid: u32
}

// PROPVARIANT (24 bytes); only the VT_LPWSTR case is read
priv struct PROPVARIANT {
    vt: u16
    reserved1: u16
    reserved2: u16
    reserved3: u16
    pwszVal: *u16
    rest: u64
}

// WAVEFORMATEX (the first 18 bytes) followed by the WAVEFORMATEXTENSIBLE fields, which are only
// present when wFormatTag is WAVE_FORMAT_EXTENSIBLE
priv struct WAVEFORMATEXTENSIBLE {
    wFormatTag: u16
    nChannels: u16
    nSamplesPerSec: u32
    nAvgBytesPerSec: u32
    nBlockAlign: u16
    wBitsPerSample: u16
    cbSize: u16
    wValidBitsPerSample: u16
    dwChannelMask: u32
    SubFormat: GUID
}

// COM interfaces: the vtable slots in order; slots this file never calls are `*u8`
priv struct IMMDeviceEnumerator { vt: *IMMDeviceEnumeratorVtbl }
priv struct IMMDeviceEnumeratorVtbl {
    QueryInterface: *u8
    AddRef: *u8
    Release: fn(*IMMDeviceEnumerator) -> u32
    EnumAudioEndpoints: fn(*IMMDeviceEnumerator, i32, u32, **IMMDeviceCollection) -> i32
    GetDefaultAudioEndpoint: fn(*IMMDeviceEnumerator, i32, i32, **IMMDevice) -> i32
}

priv struct IMMDeviceCollection { vt: *IMMDeviceCollectionVtbl }
priv struct IMMDeviceCollectionVtbl {
    QueryInterface: *u8
    AddRef: *u8
    Release: fn(*IMMDeviceCollection) -> u32
    GetCount: fn(*IMMDeviceCollection, *u32) -> i32
    Item: fn(*IMMDeviceCollection, u32, **IMMDevice) -> i32
}

priv struct IMMDevice { vt: *IMMDeviceVtbl }
priv struct IMMDeviceVtbl {
    QueryInterface: *u8
    AddRef: *u8
    Release: fn(*IMMDevice) -> u32
    Activate: fn(*IMMDevice, *GUID, u32, *PROPVARIANT, **u8) -> i32
    OpenPropertyStore: fn(*IMMDevice, u32, **IPropertyStore) -> i32
    GetId: fn(*IMMDevice, **u16) -> i32
}

priv struct IPropertyStore { vt: *IPropertyStoreVtbl }
priv struct IPropertyStoreVtbl {
    QueryInterface: *u8
    AddRef: *u8
    Release: fn(*IPropertyStore) -> u32
    GetCount: *u8
    GetAt: *u8
    GetValue: fn(*IPropertyStore, *PROPERTYKEY, *PROPVARIANT) -> i32
}

priv struct IAudioClient { vt: *IAudioClientVtbl }
priv struct IAudioClientVtbl {
    QueryInterface: *u8
    AddRef: *u8
    Release: fn(*IAudioClient) -> u32
    Initialize: fn(*IAudioClient, i32, u32, i64, i64, *WAVEFORMATEXTENSIBLE, *GUID) -> i32
    GetBufferSize: fn(*IAudioClient, *u32) -> i32
    GetStreamLatency: *u8
    GetCurrentPadding: fn(*IAudioClient, *u32) -> i32
    IsFormatSupported: *u8
    GetMixFormat: fn(*IAudioClient, **WAVEFORMATEXTENSIBLE) -> i32
    GetDevicePeriod: fn(*IAudioClient, *i64, *i64) -> i32
    Start: fn(*IAudioClient) -> i32
    Stop: fn(*IAudioClient) -> i32
    Reset: fn(*IAudioClient) -> i32
    SetEventHandle: fn(*IAudioClient, *u8) -> i32
    GetService: fn(*IAudioClient, *GUID, **u8) -> i32
}

priv struct IAudioRenderClient { vt: *IAudioRenderClientVtbl }
priv struct IAudioRenderClientVtbl {
    QueryInterface: *u8
    AddRef: *u8
    Release: fn(*IAudioRenderClient) -> u32
    GetBuffer: fn(*IAudioRenderClient, u32, **u8) -> i32
    ReleaseBuffer: fn(*IAudioRenderClient, u32, u32) -> i32
}

// from mmdeviceapi.h, audioclient.h, functiondiscoverykeys_devpkey.h, ksmedia.h
priv CLSID_MMDeviceEnumerator := GUID{0xbcde0395, 0xe52f, 0x467c, [8]u8{0x8e, 0x3d, 0xc4, 0x57, 0x92, 0x91, 0x69, 0x2e}}
priv IID_IMMDeviceEnumerator := GUID{0xa95664d2, 0x9614, 0x4f35, [8]u8{0xa7, 0x46, 0xde, 0x8d, 0xb6, 0x36, 0x17, 0xe6}}
priv IID_IAudioClient := GUID{0x1cb9ad4c, 0xdbfa, 0x4c32, [8]u8{0xb1, 0x78, 0xc2, 0xf5, 0x68, 0xa7, 0x03, 0xb2}}
priv IID_IAudioRenderClient := GUID{0xf294acfc, 0x3146, 0x4483, [8]u8{0xa7, 0xbf, 0xad, 0xdc, 0xa7, 0xc2, 0x60, 0xe2}}
priv PKEY_Device_FriendlyName := PROPERTYKEY{GUID{0xa45c254e, 0xdf1c, 0x4efd, [8]u8{0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}}, 14}
priv KSDATAFORMAT_SUBTYPE_PCM := GUID{0x00000001, 0x0000, 0x0010, [8]u8{0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}}
priv KSDATAFORMAT_SUBTYPE_IEEE_FLOAT := GUID{0x00000003, 0x0000, 0x0010, [8]u8{0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}}

// The WASAPI part of an AudioDevice. dev_* describe the device side (the mix format); q holds
// mixed frames of the program's format that the resampler has not consumed yet, `pos` is the
// resampler's position in q and `step` the program frames per device frame (32.32 fixed point).
struct AudioOs {
    open: bool
    null: bool
    com: bool
    name: str
    latency_ms: i64
    enumerator: *IMMDeviceEnumerator
    device: *IMMDevice
    client: *IAudioClient
    render: *IAudioRenderClient
    event: *u8
    id: []u16
    started: bool
    dev_rate: i64
    dev_channels: i64
    dev_buffer: i64
    kind: i64
    sample_bytes: i64
    step: i64
    pos: i64
    q: []f32
    qn: i64
    qcap: i64
    last_try: u64
    last_check: u64
    reopened: i64
}

// why the last audio_open failed
priv audio_err: str

// Why the last audio_open failed: which call failed with which HRESULT, or that there is no
// playback device ("WASAPI: no playback device ..."); "" after a successful open.
fn audio_error() -> str {
    audio_err
}

priv fn wa_hr(what: str, hr: i32) -> str {
    fmt("WASAPI: ", what, " failed: HRESULT 0x", hex(u64(u32(hr)), 8))
}

priv fn wa_guid_eq(a: *GUID, b: *GUID) -> bool {
    if a.Data1 != b.Data1 || a.Data2 != b.Data2 || a.Data3 != b.Data3 {
        return false
    }
    for i in 0..8 {
        if a.Data4[i] != b.Data4[i] {
            return false
        }
    }
    true
}

// UTF-8 text of a NUL-terminated UTF-16 string (allocates)
priv fn wa_utf8(w: *u16) -> str {
    out := vec[u8]()
    if w == nil {
        return out.items()
    }
    i := 0
    while w[i] != 0 {
        c := u32(w[i])
        i += 1
        if c >= 0xd800 && c < 0xdc00 && w[i] >= 0xdc00 && w[i] < 0xe000 {
            c = 0x10000 + ((c - 0xd800) << 10) + (u32(w[i]) - 0xdc00)
            i += 1
        }
        if c < 0x80 {
            out.push(u8(c))
        } else if c < 0x800 {
            out.push(u8(0xc0 | c >> 6))
            out.push(u8(0x80 | c & 0x3f))
        } else if c < 0x10000 {
            out.push(u8(0xe0 | c >> 12))
            out.push(u8(0x80 | c >> 6 & 0x3f))
            out.push(u8(0x80 | c & 0x3f))
        } else {
            out.push(u8(0xf0 | c >> 18))
            out.push(u8(0x80 | c >> 12 & 0x3f))
            out.push(u8(0x80 | c >> 6 & 0x3f))
            out.push(u8(0x80 | c & 0x3f))
        }
    }
    out.items()
}

// true if the NUL-terminated `w` holds exactly the units of `id`
priv fn wa_id_eq(w: *u16, id: []u16) -> bool {
    if w == nil {
        return false
    }
    for i in 0..len(id) {
        if w[i] != id[i] {
            return false
        }
    }
    w[len(id)] == 0
}

// the endpoint ID of a device as UTF-16 units without the NUL (allocates); empty on failure
priv fn wa_device_id(dev: *IMMDevice) -> []u16 {
    p: *u16 = nil
    if dev.vt.GetId(dev, &p) < 0 || p == nil {
        return []u16{}
    }
    n := 0
    while p[n] != 0 {
        n += 1
    }
    id := alloc[u16](n)
    for i in 0..n {
        id[i] = p[i]
    }
    CoTaskMemFree(cast[*u8](p))
    id
}

// the friendly name of an endpoint ("Speakers (Realtek High Definition Audio)"); "" if unknown
priv fn wa_friendly_name(dev: *IMMDevice) -> str {
    store: *IPropertyStore = nil
    if dev.vt.OpenPropertyStore(dev, STGM_READ, &store) < 0 || store == nil {
        return ""
    }
    v: PROPVARIANT
    name := ""
    if store.vt.GetValue(store, &PKEY_Device_FriendlyName, &v) >= 0 {
        if v.vt == VT_LPWSTR {
            name = wa_utf8(v.pwszVal)
        }
        PropVariantClear(&v)
    }
    store.vt.Release(store)
    name
}

// CoInitializeEx for this thread; (usable, must call CoUninitialize). A thread that already
// uses another apartment model (RPC_E_CHANGED_MODE) can use COM as it is.
priv fn wa_com_init() -> (bool, bool) {
    hr := CoInitializeEx(nil, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE)
    if hr >= 0 {
        return (true, true)
    }
    if hr == RPC_E_CHANGED_MODE {
        return (true, false)
    }
    audio_err = wa_hr("CoInitializeEx", hr)
    (false, false)
}

priv fn wa_enumerator() -> *IMMDeviceEnumerator {
    e: *IMMDeviceEnumerator = nil
    hr := CoCreateInstance(&CLSID_MMDeviceEnumerator, nil, CLSCTX_ALL, &IID_IMMDeviceEnumerator, cast[**u8](&e))
    if hr < 0 || e == nil {
        audio_err = wa_hr("CoCreateInstance(MMDeviceEnumerator)", hr)
        return nil
    }
    e
}

// The render endpoint for `name`: "default" is the default device (role eConsole), anything
// else an active endpoint whose friendly name or endpoint ID equals it. nil if there is none
// (audio_err says why).
priv fn wa_find(e: *IMMDeviceEnumerator, name: str) -> *IMMDevice {
    dev: *IMMDevice = nil
    if name == "default" {
        hr := e.vt.GetDefaultAudioEndpoint(e, eRender, eConsole, &dev)
        if hr < 0 || dev == nil {
            audio_err = if hr == E_NOTFOUND {
                "WASAPI: no playback device (GetDefaultAudioEndpoint: HRESULT 0x80070490, E_NOTFOUND)"
            } else {
                wa_hr("GetDefaultAudioEndpoint", hr)
            }
            return nil
        }
        return dev
    }
    all: *IMMDeviceCollection = nil
    hr := e.vt.EnumAudioEndpoints(e, eRender, DEVICE_STATE_ACTIVE, &all)
    if hr < 0 || all == nil {
        audio_err = wa_hr("EnumAudioEndpoints", hr)
        return nil
    }
    count: u32 = 0
    all.vt.GetCount(all, &count)
    mk := mark()
    for i in 0..i64(count) {
        d: *IMMDevice = nil
        if all.vt.Item(all, u32(i), &d) < 0 || d == nil {
            continue
        }
        if wa_friendly_name(d) == name || wa_utf8(cast[*u16](ptr(wa_device_id(d)))) == name {
            dev = d
            break
        }
        d.vt.Release(d)
    }
    release(mk)
    all.vt.Release(all)
    if dev == nil {
        audio_err = fmt("WASAPI: no playback device named \"", name, "\" (audio_devices() lists them)")
    }
    dev
}

// releases the stream and the device (keeps the enumerator, the event and the queue)
priv fn wa_disconnect(d: *AudioDevice) {
    o := &d.os
    if o.client != nil && o.started {
        o.client.vt.Stop(o.client)
    }
    if o.render != nil {
        o.render.vt.Release(o.render)
        o.render = nil
    }
    if o.client != nil {
        o.client.vt.Release(o.client)
        o.client = nil
    }
    if o.device != nil {
        o.device.vt.Release(o.device)
        o.device = nil
    }
    o.started = false
}

// Opens the device named o.name and initialises a stream in its mix format; on failure
// everything acquired is released again and audio_err says why.
priv fn wa_connect(d: *AudioDevice) -> bool {
    o := &d.os
    if o.enumerator == nil {
        o.enumerator = wa_enumerator()
        if o.enumerator == nil {
            return false
        }
    }
    o.device = wa_find(o.enumerator, o.name)
    if o.device == nil {
        return false
    }
    hr := o.device.vt.Activate(o.device, &IID_IAudioClient, CLSCTX_ALL, nil, cast[**u8](&o.client))
    if hr < 0 || o.client == nil {
        o.client = nil
        audio_err = wa_hr("IMMDevice::Activate(IAudioClient)", hr)
        wa_disconnect(d)
        return false
    }
    mf: *WAVEFORMATEXTENSIBLE = nil
    hr = o.client.vt.GetMixFormat(o.client, &mf)
    if hr < 0 || mf == nil {
        audio_err = wa_hr("IAudioClient::GetMixFormat", hr)
        wa_disconnect(d)
        return false
    }
    tag := mf.wFormatTag
    if tag == WAVE_FORMAT_EXTENSIBLE && mf.cbSize >= 22 {
        if wa_guid_eq(&mf.SubFormat, &KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) {
            tag = WAVE_FORMAT_IEEE_FLOAT
        } else if wa_guid_eq(&mf.SubFormat, &KSDATAFORMAT_SUBTYPE_PCM) {
            tag = WAVE_FORMAT_PCM
        }
    }
    channels := i64(mf.nChannels)
    rate := i64(mf.nSamplesPerSec)
    bytes := if channels > 0 { i64(mf.nBlockAlign) / channels } else { 0 }
    kind := -1
    if tag == WAVE_FORMAT_IEEE_FLOAT && bytes == 4 {
        kind = WA_F32
    } else if tag == WAVE_FORMAT_PCM && bytes == 2 {
        kind = WA_I16
    } else if tag == WAVE_FORMAT_PCM && bytes == 3 {
        kind = WA_I24
    } else if tag == WAVE_FORMAT_PCM && bytes == 4 {
        kind = WA_I32
    }
    if kind < 0 || rate <= 0 {
        audio_err = fmt("WASAPI: unsupported mix format (tag 0x", hex(u64(mf.wFormatTag)), ", ", mf.wBitsPerSample, " bits, ", channels, " channels, ", rate, " Hz)")
        CoTaskMemFree(cast[*u8](mf))
        wa_disconnect(d)
        return false
    }
    hr = o.client.vt.Initialize(o.client, AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK, max(o.latency_ms, 0) * 10000, 0, mf, nil)
    CoTaskMemFree(cast[*u8](mf))
    if hr < 0 {
        audio_err = wa_hr("IAudioClient::Initialize", hr)
        wa_disconnect(d)
        return false
    }
    frames: u32 = 0
    period: i64 = 0
    min_period: i64 = 0
    hr = o.client.vt.GetBufferSize(o.client, &frames)
    if hr >= 0 {
        hr = o.client.vt.GetDevicePeriod(o.client, &period, &min_period)
    }
    if hr >= 0 && o.event == nil {
        o.event = CreateEventW(nil, 0, 0, nil)
    }
    if hr >= 0 {
        hr = o.client.vt.SetEventHandle(o.client, o.event)
    }
    if hr >= 0 {
        hr = o.client.vt.GetService(o.client, &IID_IAudioRenderClient, cast[**u8](&o.render))
    }
    if hr < 0 || o.render == nil || frames == 0 {
        o.render = nil
        audio_err = wa_hr("setting up the IAudioClient stream", hr)
        wa_disconnect(d)
        return false
    }
    o.id = wa_device_id(o.device)
    o.dev_rate = rate
    o.dev_channels = channels
    o.dev_buffer = i64(frames)
    o.kind = kind
    o.sample_bytes = bytes
    o.step = ((d.rate << 32) + rate / 2) / rate
    o.pos = 0
    o.qn = 0
    // one output frame needs at most step + 2 queued frames
    o.qcap = AUDIO_CHUNK_FRAMES + 2 * (d.rate / rate + 2)
    if len(o.q) < o.qcap * d.channels {
        o.q = alloc[f32](o.qcap * d.channels)
    }
    d.buffer_frames = o.dev_buffer * d.rate / rate
    d.period_frames = period * d.rate / 10000000
    true
}

// Opens a playback device for `rate` Hz and `channels` channels with about `latency_ms` of
// buffering: "default" is the default device (and follows it when the user picks another),
// another name an endpoint from audio_devices() (friendly name or endpoint ID), "null" a
// device that discards everything at once (like ALSA's "null"). The device's own format may
// differ: the samples are converted (see the top of this file). Allocates the device once.
fn audio_open(name: str, rate: i64, channels: i64, latency_ms: i64) -> (*AudioDevice, bool) {
    if rate <= 0 || channels <= 0 {
        audio_err = fmt("audio_open: bad format (", rate, " Hz, ", channels, " channels)")
        return (nil, false)
    }
    d := new[AudioDevice]()
    d.rate = rate
    d.channels = channels
    o := &d.os
    o.name = clone(name)
    o.latency_ms = latency_ms
    if name == "null" {
        o.null = true
        o.open = true
        d.buffer_frames = max(latency_ms * rate / 1000, 1)
        d.period_frames = max(d.buffer_frames / 4, 1)
        o.qcap = AUDIO_CHUNK_FRAMES
        o.q = alloc[f32](o.qcap * channels)
        audio_err = ""
        return (d, true)
    }
    usable, com := wa_com_init()
    if !usable {
        return (nil, false)
    }
    o.com = com
    if !wa_connect(d) {
        if o.enumerator != nil {
            o.enumerator.vt.Release(o.enumerator)
            o.enumerator = nil
        }
        if o.event != nil {
            CloseHandle(o.event)
        }
        if com {
            CoUninitialize()
        }
        return (nil, false)
    }
    o.open = true
    o.last_check = GetTickCount64()
    audio_err = ""
    (d, true)
}

// a failed call: the stream is gone (AUDCLNT_E_DEVICE_INVALIDATED: unplugged, disabled, format
// changed; or any other failure); audio_pump / audio_write try to open the device again
priv fn wa_lost(d: *AudioDevice, hr: i32) {
    wa_disconnect(d)
    d.lost = true
    // right away for a device that went away (the new default is usually there already)
    d.os.last_try = if hr == AUDCLNT_E_DEVICE_INVALIDATED { 0 } else { GetTickCount64() }
}

// True if the stream can be written: reopens a lost device (at most every WA_RETRY_MS) and
// moves a "default" device to a new default endpoint.
priv fn wa_ready(d: *AudioDevice) -> bool {
    o := &d.os
    now := GetTickCount64()
    if d.lost {
        if o.last_try != 0 && now - o.last_try < WA_RETRY_MS {
            return false
        }
        o.last_try = now
        // a failed attempt gives back what it allocated (also its error text: audio_error
        // stays about audio_open), so a device that stays away costs no memory
        saved := audio_err
        mk := mark()
        if !wa_connect(d) {
            release(mk)
            audio_err = saved
            return false
        }
        d.lost = false
        o.reopened += 1
        o.last_check = now
        return true
    }
    if o.name == "default" && now - o.last_check >= WA_DEFAULT_CHECK_MS {
        o.last_check = now
        dev: *IMMDevice = nil
        if o.enumerator.vt.GetDefaultAudioEndpoint(o.enumerator, eRender, eConsole, &dev) >= 0 && dev != nil {
            p: *u16 = nil
            same := true
            if dev.vt.GetId(dev, &p) >= 0 && p != nil {
                same = wa_id_eq(p, o.id)
                CoTaskMemFree(cast[*u8](p))
            }
            dev.vt.Release(dev)
            if !same {
                wa_lost(d, AUDCLNT_E_DEVICE_INVALIDATED)
                return wa_ready(d)
            }
        }
    }
    true
}

// device frames that the queued frames can produce now
priv fn wa_producible(o: *AudioOs) -> i64 {
    if o.qn == 0 {
        return 0
    }
    lim := (o.qn - 1) << 32
    if o.pos > lim {
        return 0
    }
    (lim - o.pos) / o.step + 1
}

// queued frames needed to produce `n` device frames
priv fn wa_needed(o: *AudioOs, n: i64) -> i64 {
    p := o.pos + (n - 1) * o.step
    (p >> 32) + if p & 0xFFFFFFFF != 0 { 2 } else { 1 }
}

// stores one sample in the mix format's type
priv fn wa_store(o: *AudioOs, out: *u8, j: i64, v: f32) {
    match o.kind {
        WA_F32 => cast[*f32](out)[j] = v
        WA_I16 => cast[*i16](out)[j] = i16(min(max(i64(floor(f64(v) * 32767.0 + 0.5)), -32768), 32767))
        WA_I24 => {
            x := min(max(i64(floor(f64(v) * 8388607.0 + 0.5)), -8388608), 8388607)
            out[j * 3] = u8(x)
            out[j * 3 + 1] = u8(x >> 8)
            out[j * 3 + 2] = u8(x >> 16)
        }
        _ => cast[*i32](out)[j] = i32(min(max(i64(floor(f64(v) * 2147483647.0 + 0.5)), -2147483648), 2147483647))
    }
}

// Converts up to `n` device frames from the queue into `out` (the device buffer); returns how
// many it produced and drops the queued frames no longer needed.
priv fn wa_produce(d: *AudioDevice, out: *u8, n: i64) -> i64 {
    o := &d.os
    c := d.channels
    dc := o.dev_channels
    q := o.q
    k := 0
    while k < n {
        i0 := o.pos >> 32
        frac := o.pos & 0xFFFFFFFF
        if i0 >= o.qn || (frac != 0 && i0 + 1 >= o.qn) {
            break
        }
        t := f32(frac) * (1.0 / 4294967296.0)
        a := i0 * c
        b := if frac != 0 { a + c } else { a }
        base := k * dc
        if dc == 1 {
            s: f32 = 0.0
            for ch in 0..c {
                s += q[a + ch] + (q[b + ch] - q[a + ch]) * t
            }
            wa_store(o, out, base, s / f32(c))
        } else if c == 1 {
            s := q[a] + (q[b] - q[a]) * t
            wa_store(o, out, base, s)
            wa_store(o, out, base + 1, s)
            for ch in 2..dc {
                wa_store(o, out, base + ch, 0.0)
            }
        } else {
            for ch in 0..dc {
                s: f32 = 0.0
                if ch < c {
                    s = q[a + ch] + (q[b + ch] - q[a + ch]) * t
                }
                wa_store(o, out, base + ch, s)
            }
        }
        o.pos += o.step
        k += 1
    }
    drop := min(o.pos >> 32, o.qn)
    if drop > 0 {
        rest := (o.qn - drop) * c
        for i in 0..rest {
            q[i] = q[drop * c + i]
        }
        o.qn -= drop
        o.pos -= drop << 32
    }
    k
}

// mixes `n` more program frames into the queue (n <= free queue space)
priv fn wa_mix(d: *AudioDevice, m: *Mixer, n: i64) {
    o := &d.os
    mix(m, o.q[o.qn * d.channels..(o.qn + n) * d.channels], n)
    o.qn += n
}

// Fills `n` device frames: takes the device buffer, mixes as many program frames as the
// conversion needs (pump) or converts only what is queued (n <= wa_producible), releases the
// buffer and starts the stream after its first data. Returns the program frames mixed.
priv fn wa_submit(d: *AudioDevice, m: *Mixer, n: i64, mixing: bool) -> i64 {
    o := &d.os
    buf: *u8 = nil
    hr := o.render.vt.GetBuffer(o.render, u32(n), &buf)
    if hr < 0 || buf == nil {
        wa_lost(d, hr)
        return 0
    }
    frame_bytes := o.dev_channels * o.sample_bytes
    mixed := 0
    done := 0
    while done < n {
        if mixing {
            add := min(max(wa_needed(o, n - done) - o.qn, 0), o.qcap - o.qn)
            if add > 0 {
                wa_mix(d, m, add)
                mixed += add
            }
        }
        k := wa_produce(d, cast[*u8](cast[i64](buf) + done * frame_bytes), n - done)
        if k == 0 {
            break
        }
        done += k
    }
    hr = o.render.vt.ReleaseBuffer(o.render, u32(done), 0)
    if hr < 0 {
        wa_lost(d, hr)
        return mixed
    }
    if !o.started && done > 0 {
        hr = o.client.vt.Start(o.client)
        if hr < 0 {
            wa_lost(d, hr)
            return mixed
        }
        o.started = true
    }
    mixed
}

// free device frames now, or -1 if the stream failed; counts an empty buffer of a running
// stream as an underrun (the engine played silence)
priv fn wa_free(d: *AudioDevice) -> i64 {
    o := &d.os
    padding: u32 = 0
    hr := o.client.vt.GetCurrentPadding(o.client, &padding)
    if hr < 0 {
        wa_lost(d, hr)
        return -1
    }
    if o.started && padding == 0 {
        d.underruns += 1
    }
    o.dev_buffer - i64(padding)
}

// Mixes the next `count` frames and writes them to the device, waiting while the device
// buffer is full (so it paces a loop to real time). Returns the frames written: fewer if the
// device is lost (then it waits for up to the length of the missing frames, at most 100 ms,
// so that a loop around it does not spin). Does nothing for a nil or closed device.
fn audio_write(d: *AudioDevice, m: *Mixer, count: i64) -> i64 {
    if d == nil || !d.os.open {
        return 0
    }
    assert m.rate == d.rate && m.channels == d.channels, "audio_write: mixer and device formats differ"
    o := &d.os
    total := 0
    if o.null {
        while total < count {
            n := min(count - total, o.qcap)
            mix(m, o.q, n)
            total += n
        }
        return total
    }
    while true {
        if !wa_ready(d) {
            Sleep(u32(min(max((count - total) * 1000 / d.rate, 1), 100)))
            return total
        }
        if total < count && o.qn < o.qcap {
            n := min(count - total, o.qcap - o.qn)
            wa_mix(d, m, n)
            total += n
        }
        avail := wa_producible(o)
        if avail == 0 {
            if total == count {
                break
            }
            continue
        }
        free := wa_free(d)
        if free < 0 {
            continue
        }
        if free == 0 {
            WaitForSingleObject(o.event, 200)
            continue
        }
        wa_submit(d, m, min(free, avail), false)
    }
    total
}

// Tops the device buffer up with as many frames as it accepts right now, without waiting.
// Call it once per frame; returns the frames mixed (0 while the device is lost). Does nothing
// for a nil or closed device.
fn audio_pump(d: *AudioDevice, m: *Mixer) -> i64 {
    if d == nil || !d.os.open {
        return 0
    }
    if d.os.null {
        return audio_write(d, m, d.buffer_frames)
    }
    assert m.rate == d.rate && m.channels == d.channels, "audio_pump: mixer and device formats differ"
    if !wa_ready(d) {
        return 0
    }
    free := wa_free(d)
    if free <= 0 {
        return 0
    }
    wa_submit(d, m, free, true)
}

// Stops playback at once and closes the device.
fn audio_close(d: *AudioDevice) {
    if d == nil || !d.os.open {
        return
    }
    o := &d.os
    o.open = false
    if o.null {
        return
    }
    wa_disconnect(d)
    if o.enumerator != nil {
        o.enumerator.vt.Release(o.enumerator)
        o.enumerator = nil
    }
    if o.event != nil {
        CloseHandle(o.event)
        o.event = nil
    }
    if o.com {
        CoUninitialize()
        o.com = false
    }
}

// The friendly names of the active playback endpoints ("Speakers (Realtek(R) Audio)", ...), in
// the system's order; audio_open also accepts "default" and "null". Empty if there are none or
// COM / the audio service is not available. Allocates the list.
fn audio_devices() -> []str {
    names := vec[str]()
    usable, com := wa_com_init()
    if !usable {
        return names.items()
    }
    e := wa_enumerator()
    if e != nil {
        all: *IMMDeviceCollection = nil
        if e.vt.EnumAudioEndpoints(e, eRender, DEVICE_STATE_ACTIVE, &all) >= 0 && all != nil {
            count: u32 = 0
            all.vt.GetCount(all, &count)
            for i in 0..i64(count) {
                dev: *IMMDevice = nil
                if all.vt.Item(all, u32(i), &dev) >= 0 && dev != nil {
                    names.push(wa_friendly_name(dev))
                    dev.vt.Release(dev)
                }
            }
            all.vt.Release(all)
        }
        e.vt.Release(e)
    }
    if com {
        CoUninitialize()
    }
    names.items()
}
