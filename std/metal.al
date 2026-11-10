// std.metal: Apple's Metal for AL, through the Objective-C runtime: the core Metal API (`mtl_`),
// CAMetalLayer (`ca_`), the AppKit pieces needed to open a window and pump events (`ns_`) and
// the runtime itself (`objc_`, `sel`, the `msg_*` family).
//
// AL has no macOS backend yet: programs using this module type-check (`alc check`) but cannot
// be built. See docs/std/metal.md for the mapping rules, ownership, the calling-convention
// notes and a walk-through of tests/check/metal_triangle.al.
//
//   device := mtl_create_system_default_device()
//   queue := device.mtl_new_command_queue()
//   buffer := device.mtl_new_buffer_with_bytes(ptr(vertices), size, MTLResourceStorageModeShared)
//
// Objects are typed pointers (`*MTLDevice`, `*MTLTexture`, ...); nil is a valid receiver and
// makes every message a no-op, as in Objective-C. Functions named `..._new` / `mtl_new_...`
// return an object the caller owns (`objc_release`); everything else is autoreleased and lives
// until the enclosing `objc_autoreleasePoolPop`.

// ---- Objective-C runtime --------------------------------------------------------------------

// The class object with a NUL-terminated name; nil if no loaded framework defines it.
extern "/usr/lib/libobjc.A.dylib" fn objc_getClass(name *u8) *u8
// The selector for a NUL-terminated method name.
extern "/usr/lib/libobjc.A.dylib" fn sel_registerName(name *u8) *u8
// The message dispatcher. It has no signature of its own: every call goes through one of the
// `msg_*` functions below, which cast it to the C signature of the message being sent.
extern "/usr/lib/libobjc.A.dylib" fn objc_msgSend()
// Opens an autorelease pool; pass the result to objc_autoreleasePoolPop.
extern "/usr/lib/libobjc.A.dylib" fn objc_autoreleasePoolPush() *u8
// Closes a pool: releases every object autoreleased since the matching push.
extern "/usr/lib/libobjc.A.dylib" fn objc_autoreleasePoolPop(pool *u8)
// Starts the definition of a new class (for delegates implemented in AL); nil if the name is taken.
extern "/usr/lib/libobjc.A.dylib" fn objc_allocateClassPair(superclass *u8, name *u8, extra_bytes u64) *u8
// Adds a method: `imp` is an AL function `fn(self *u8, cmd *u8, ...)` cast to *u8, `types` its type encoding ("v@:@").
extern "/usr/lib/libobjc.A.dylib" fn class_addMethod(class *u8, selector *u8, imp *u8, types *u8) bool
// Finishes a class started with objc_allocateClassPair.
extern "/usr/lib/libobjc.A.dylib" fn objc_registerClassPair(class *u8)
// The preferred GPU, or nil if the machine has none that supports Metal (owned by the caller).
extern "/System/Library/Frameworks/Metal.framework/Metal" fn MTLCreateSystemDefaultDevice() *u8
// Seconds on the host clock that display timing uses; for frame timing.
extern "/System/Library/Frameworks/QuartzCore.framework/QuartzCore" fn CACurrentMediaTime() f64
// Makes sure AppKit is initialised (this reference is also what loads AppKit, QuartzCore and Foundation).
extern "/System/Library/Frameworks/AppKit.framework/AppKit" fn NSApplicationLoad() bool

// The class `name` (a string literal), looked up on first use and cached in `*slot`.
inline fn objc_class(slot **u8, name str) *u8 {
    if *slot == nil {
        *slot = objc_getClass(ptr(name))
    }
    *slot
}

// The selector `name` (a string literal), registered on first use and cached in `*slot`.
inline fn sel(slot **u8, name str) *u8 {
    if *slot == nil {
        *slot = sel_registerName(ptr(name))
    }
    *slot
}

// The msg_* family: objc_msgSend cast to one C signature each. The name gives the result
// (id = object or pointer, void, u64, bool, f64) and then one letter per argument:
// p pointer/object, u u64 (NSUInteger), i i64 (NSInteger), b bool (BOOL), d f64 (CGFloat,
// double), f f32 (float). Receiver and pointer arguments accept any pointer type.

// Sends a message without arguments that returns an object or pointer.
inline fn msg_id[O, R](obj *O, s *u8) *R { cast[*R](cast[fn(*u8, *u8) *u8](objc_msgSend)(cast[*u8](obj), s)) }
// Sends `id (id)`.
inline fn msg_id_p[O, A, R](obj *O, s *u8, a *A) *R { cast[*R](cast[fn(*u8, *u8, *u8) *u8](objc_msgSend)(cast[*u8](obj), s, cast[*u8](a))) }
// Sends `id (id, id)`.
inline fn msg_id_pp[O, A, B, R](obj *O, s *u8, a *A, b *B) *R { cast[*R](cast[fn(*u8, *u8, *u8, *u8) *u8](objc_msgSend)(cast[*u8](obj), s, cast[*u8](a), cast[*u8](b))) }
// Sends `id (id, id, id)`.
inline fn msg_id_ppp[O, A, B, C, R](obj *O, s *u8, a *A, b *B, c *C) *R { cast[*R](cast[fn(*u8, *u8, *u8, *u8, *u8) *u8](objc_msgSend)(cast[*u8](obj), s, cast[*u8](a), cast[*u8](b), cast[*u8](c))) }
// Sends `id (NSUInteger)`.
inline fn msg_id_u[O, R](obj *O, s *u8, a u64) *R { cast[*R](cast[fn(*u8, *u8, u64) *u8](objc_msgSend)(cast[*u8](obj), s, a)) }
// Sends `id (NSUInteger, NSUInteger)`.
inline fn msg_id_uu[O, R](obj *O, s *u8, a u64, b u64) *R { cast[*R](cast[fn(*u8, *u8, u64, u64) *u8](objc_msgSend)(cast[*u8](obj), s, a, b)) }
// Sends `id (pointer, NSUInteger, NSUInteger)`.
inline fn msg_id_puu[O, A, R](obj *O, s *u8, a *A, b u64, c u64) *R { cast[*R](cast[fn(*u8, *u8, *u8, u64, u64) *u8](objc_msgSend)(cast[*u8](obj), s, cast[*u8](a), b, c)) }
// Sends `id (NSUInteger, NSUInteger, NSUInteger, BOOL)`.
inline fn msg_id_uuub[O, R](obj *O, s *u8, a u64, b u64, c u64, d bool) *R { cast[*R](cast[fn(*u8, *u8, u64, u64, u64, bool) *u8](objc_msgSend)(cast[*u8](obj), s, a, b, c, d)) }
// Sends `id (NSUInteger, id, id, BOOL)`.
inline fn msg_id_uppb[O, A, B, R](obj *O, s *u8, a u64, b *A, c *B, d bool) *R { cast[*R](cast[fn(*u8, *u8, u64, *u8, *u8, bool) *u8](objc_msgSend)(cast[*u8](obj), s, a, cast[*u8](b), cast[*u8](c), d)) }
// Sends `id (NSRect as 4 doubles, NSUInteger, NSUInteger, BOOL)`.
inline fn msg_id_dddduub[O, R](obj *O, s *u8, a f64, b f64, c f64, d f64, e u64, f u64, g bool) *R { cast[*R](cast[fn(*u8, *u8, f64, f64, f64, f64, u64, u64, bool) *u8](objc_msgSend)(cast[*u8](obj), s, a, b, c, d, e, f, g)) }
// Sends `void ()`.
inline fn msg_void[O](obj *O, s *u8) { cast[fn(*u8, *u8)](objc_msgSend)(cast[*u8](obj), s) }
// Sends `void (id)`.
inline fn msg_void_p[O, A](obj *O, s *u8, a *A) { cast[fn(*u8, *u8, *u8)](objc_msgSend)(cast[*u8](obj), s, cast[*u8](a)) }
// Sends `void (id, id)`.
inline fn msg_void_pp[O, A, B](obj *O, s *u8, a *A, b *B) { cast[fn(*u8, *u8, *u8, *u8)](objc_msgSend)(cast[*u8](obj), s, cast[*u8](a), cast[*u8](b)) }
// Sends `void (id, NSUInteger)`.
inline fn msg_void_pu[O, A](obj *O, s *u8, a *A, b u64) { cast[fn(*u8, *u8, *u8, u64)](objc_msgSend)(cast[*u8](obj), s, cast[*u8](a), b) }
// Sends `void (id, NSUInteger, NSUInteger)`.
inline fn msg_void_puu[O, A](obj *O, s *u8, a *A, b u64, c u64) { cast[fn(*u8, *u8, *u8, u64, u64)](objc_msgSend)(cast[*u8](obj), s, cast[*u8](a), b, c) }
// Sends `void (pointer, NSUInteger, pointer, NSUInteger)`.
inline fn msg_void_pupu[O, A, B](obj *O, s *u8, a *A, b u64, c *B, d u64) { cast[fn(*u8, *u8, *u8, u64, *u8, u64)](objc_msgSend)(cast[*u8](obj), s, cast[*u8](a), b, cast[*u8](c), d) }
// Sends `void (id, NSUInteger, id, NSUInteger, NSUInteger)`.
inline fn msg_void_pupuu[O, A, B](obj *O, s *u8, a *A, b u64, c *B, d u64, e u64) { cast[fn(*u8, *u8, *u8, u64, *u8, u64, u64)](objc_msgSend)(cast[*u8](obj), s, cast[*u8](a), b, cast[*u8](c), d, e) }
// Sends `void (id, NSUInteger, NSUInteger, pointer, pointer, id, NSUInteger, NSUInteger, pointer)`.
inline fn msg_void_puupppuup[O, A, B, C, D, E](obj *O, s *u8, a *A, b u64, c u64, d *B, e *C, f *D, g u64, h u64, i *E) { cast[fn(*u8, *u8, *u8, u64, u64, *u8, *u8, *u8, u64, u64, *u8)](objc_msgSend)(cast[*u8](obj), s, cast[*u8](a), b, c, cast[*u8](d), cast[*u8](e), cast[*u8](f), g, h, cast[*u8](i)) }
// Sends `void (NSUInteger)`.
inline fn msg_void_u[O](obj *O, s *u8, a u64) { cast[fn(*u8, *u8, u64)](objc_msgSend)(cast[*u8](obj), s, a) }
// Sends `void (NSUInteger, NSUInteger)`; also an NSRange, which travels as two integers.
inline fn msg_void_uu[O](obj *O, s *u8, a u64, b u64) { cast[fn(*u8, *u8, u64, u64)](objc_msgSend)(cast[*u8](obj), s, a, b) }
// Sends `void (NSUInteger, NSUInteger, NSUInteger)`.
inline fn msg_void_uuu[O](obj *O, s *u8, a u64, b u64, c u64) { cast[fn(*u8, *u8, u64, u64, u64)](objc_msgSend)(cast[*u8](obj), s, a, b, c) }
// Sends `void (NSUInteger, NSUInteger, NSUInteger, NSUInteger)`.
inline fn msg_void_uuuu[O](obj *O, s *u8, a u64, b u64, c u64, d u64) { cast[fn(*u8, *u8, u64, u64, u64, u64)](objc_msgSend)(cast[*u8](obj), s, a, b, c, d) }
// Sends `void (NSUInteger, NSUInteger, NSUInteger, id, NSUInteger)`.
inline fn msg_void_uuupu[O, A](obj *O, s *u8, a u64, b u64, c u64, d *A, e u64) { cast[fn(*u8, *u8, u64, u64, u64, *u8, u64)](objc_msgSend)(cast[*u8](obj), s, a, b, c, cast[*u8](d), e) }
// Sends `void (NSUInteger, NSUInteger, NSUInteger, id, NSUInteger, NSUInteger)`.
inline fn msg_void_uuupuu[O, A](obj *O, s *u8, a u64, b u64, c u64, d *A, e u64, f u64) { cast[fn(*u8, *u8, u64, u64, u64, *u8, u64, u64)](objc_msgSend)(cast[*u8](obj), s, a, b, c, cast[*u8](d), e, f) }
// Sends `void (NSInteger)`.
inline fn msg_void_i[O](obj *O, s *u8, a i64) { cast[fn(*u8, *u8, i64)](objc_msgSend)(cast[*u8](obj), s, a) }
// Sends `void (BOOL)`.
inline fn msg_void_b[O](obj *O, s *u8, a bool) { cast[fn(*u8, *u8, bool)](objc_msgSend)(cast[*u8](obj), s, a) }
// Sends `void (double)`.
inline fn msg_void_d[O](obj *O, s *u8, a f64) { cast[fn(*u8, *u8, f64)](objc_msgSend)(cast[*u8](obj), s, a) }
// Sends `void (double, double)`; also a CGSize or CGPoint, which travel as two doubles.
inline fn msg_void_dd[O](obj *O, s *u8, a f64, b f64) { cast[fn(*u8, *u8, f64, f64)](objc_msgSend)(cast[*u8](obj), s, a, b) }
// Sends `void (double, double, double, double)`; on arm64 also an MTLClearColor or CGRect.
inline fn msg_void_dddd[O](obj *O, s *u8, a f64, b f64, c f64, d f64) { cast[fn(*u8, *u8, f64, f64, f64, f64)](objc_msgSend)(cast[*u8](obj), s, a, b, c, d) }
// Sends `void (float)`.
inline fn msg_void_f[O](obj *O, s *u8, a f32) { cast[fn(*u8, *u8, f32)](objc_msgSend)(cast[*u8](obj), s, a) }
// Sends `void (float, float, float)`.
inline fn msg_void_fff[O](obj *O, s *u8, a f32, b f32, c f32) { cast[fn(*u8, *u8, f32, f32, f32)](objc_msgSend)(cast[*u8](obj), s, a, b, c) }
// Sends `void (float, float, float, float)`.
inline fn msg_void_ffff[O](obj *O, s *u8, a f32, b f32, c f32, d f32) { cast[fn(*u8, *u8, f32, f32, f32, f32)](objc_msgSend)(cast[*u8](obj), s, a, b, c, d) }
// Sends `NSUInteger ()`.
inline fn msg_u64[O](obj *O, s *u8) u64 { cast[fn(*u8, *u8) u64](objc_msgSend)(cast[*u8](obj), s) }
// Sends `BOOL ()`.
inline fn msg_bool[O](obj *O, s *u8) bool { cast[fn(*u8, *u8) bool](objc_msgSend)(cast[*u8](obj), s) }
// Sends `BOOL (NSUInteger)`.
inline fn msg_bool_u[O](obj *O, s *u8, a u64) bool { cast[fn(*u8, *u8, u64) bool](objc_msgSend)(cast[*u8](obj), s, a) }
// Sends `double ()`.
inline fn msg_f64[O](obj *O, s *u8) f64 { cast[fn(*u8, *u8) f64](objc_msgSend)(cast[*u8](obj), s) }

var sel_alloc *u8
var sel_init *u8
var sel_retain *u8
var sel_release *u8

// A new instance of a class: `[[class alloc] init]` (owned by the caller).
fn objc_new[R](class *u8) *R {
    var raw *u8 = msg_id(class, sel(&sel_alloc, "alloc"))
    msg_id(raw, sel(&sel_init, "init"))
}

// Takes shared ownership of an object; returns it.
fn objc_retain[T](obj *T) *T { msg_id(obj, sel(&sel_retain, "retain")) }

// Gives up ownership of an object; it is destroyed when the last owner has released it.
fn objc_release[T](obj *T) { msg_void(obj, sel(&sel_release, "release")) }

// ---- Foundation -----------------------------------------------------------------------------
struct NSString { isa *u8 }
struct NSError { isa *u8 }

const NSUTF8StringEncoding u64 = 4

var cls_NSString *u8
var cls_NSDate *u8
var sel_initWithBytes_length_encoding_ *u8
var sel_UTF8String *u8
var sel_localizedDescription *u8
var sel_distantPast *u8
var sel_distantFuture *u8

// An NSString with a copy of UTF-8 text (owned by the caller).
fn ns_string(s str) *NSString {
    var raw *u8 = msg_id(objc_class(&cls_NSString, "NSString"), sel(&sel_alloc, "alloc"))
    msg_id_puu(raw, sel(&sel_initWithBytes_length_encoding_, "initWithBytes:length:encoding:"), ptr(s), u64(len(s)), NSUTF8StringEncoding)
}

// The UTF-8 text of an NSString: a view that stays valid as long as the string object does.
fn ns_string_text(s *NSString) str {
    var p *u8 = msg_id(s, sel(&sel_UTF8String, "UTF8String"))
    from_cstr(p)
}

// The human-readable message of an NSError ("" for nil).
fn ns_error_text(e *NSError) str {
    var text *NSString = msg_id(e, sel(&sel_localizedDescription, "localizedDescription"))
    ns_string_text(text)
}

// ---- AppKit: application, window, events ----------------------------------------------------
struct NSApplication { isa *u8 }
struct NSWindow { isa *u8 }
struct NSView { isa *u8 }
struct NSEvent { isa *u8 }

const NSApplicationActivationPolicyRegular i64 = 0
const NSApplicationActivationPolicyAccessory i64 = 1
const NSWindowStyleMaskTitled u64 = 1
const NSWindowStyleMaskClosable u64 = 2
const NSWindowStyleMaskMiniaturizable u64 = 4
const NSWindowStyleMaskResizable u64 = 8
const NSBackingStoreBuffered u64 = 2
const NSEventMaskAny u64 = 0xffffffffffffffff
const NSEventTypeLeftMouseDown u64 = 1
const NSEventTypeLeftMouseUp u64 = 2
const NSEventTypeRightMouseDown u64 = 3
const NSEventTypeRightMouseUp u64 = 4
const NSEventTypeMouseMoved u64 = 5
const NSEventTypeKeyDown u64 = 10
const NSEventTypeKeyUp u64 = 11
const NSEventTypeScrollWheel u64 = 22
const NS_KEY_ESCAPE u64 = 53
const NS_KEY_SPACE u64 = 49
const NS_KEY_RETURN u64 = 36

var cls_NSApplication *u8
var cls_NSWindow *u8
var ns_default_run_loop_mode *NSString
var sel_sharedApplication *u8
var sel_setActivationPolicy_ *u8
var sel_finishLaunching *u8
var sel_activateIgnoringOtherApps_ *u8
var sel_nextEventMatchingMask_untilDate_inMode_dequeue_ *u8
var sel_sendEvent_ *u8
var sel_type *u8
var sel_keyCode *u8
var sel_initWithContentRect_styleMask_backing_defer_ *u8
var sel_setReleasedWhenClosed_ *u8
var sel_setTitle_ *u8
var sel_center *u8
var sel_makeKeyAndOrderFront_ *u8
var sel_isVisible *u8
var sel_close *u8
var sel_contentView *u8
var sel_backingScaleFactor *u8
var sel_setLayer_ *u8
var sel_setWantsLayer_ *u8

// The application object (created on first use).
fn ns_app() *NSApplication {
    NSApplicationLoad()
    msg_id(objc_class(&cls_NSApplication, "NSApplication"), sel(&sel_sharedApplication, "sharedApplication"))
}

// Chooses how the application appears: NSApplicationActivationPolicyRegular gives it a Dock icon and a menu bar.
fn ns_set_activation_policy(app *NSApplication, policy i64) { msg_void_i(app, sel(&sel_setActivationPolicy_, "setActivationPolicy:"), policy) }

// Completes application start-up; call once before the first event is fetched.
fn ns_finish_launching(app *NSApplication) { msg_void(app, sel(&sel_finishLaunching, "finishLaunching")) }

// Brings the application to the front.
fn ns_activate(app *NSApplication) { msg_void_b(app, sel(&sel_activateIgnoringOtherApps_, "activateIgnoringOtherApps:"), true) }

// Removes the next event from the queue: nil if none is pending, or blocks for one if `wait`.
fn ns_next_event(app *NSApplication, wait bool) *NSEvent {
    if ns_default_run_loop_mode == nil {
        ns_default_run_loop_mode = ns_string("kCFRunLoopDefaultMode")
    }
    dates := objc_class(&cls_NSDate, "NSDate")
    var until *u8 = if wait { msg_id(dates, sel(&sel_distantFuture, "distantFuture")) } else { msg_id(dates, sel(&sel_distantPast, "distantPast")) }
    msg_id_uppb(app, sel(&sel_nextEventMatchingMask_untilDate_inMode_dequeue_, "nextEventMatchingMask:untilDate:inMode:dequeue:"),
        NSEventMaskAny, until, ns_default_run_loop_mode, true)
}

// Dispatches an event to its window (so that buttons, dragging and closing work).
fn ns_send_event(app *NSApplication, event *NSEvent) { msg_void_p(app, sel(&sel_sendEvent_, "sendEvent:"), event) }

// The kind of an event (NSEventTypeKeyDown, ...).
fn ns_type(event *NSEvent) u64 { msg_u64(event, sel(&sel_type, "type")) }

// The hardware key code of a key event (NS_KEY_ESCAPE, ...).
fn ns_key_code(event *NSEvent) u64 { msg_u64(event, sel(&sel_keyCode, "keyCode")) & 0xffff }

// A centred window with a content area of `width` x `height` points (owned by the caller; closing it does not destroy it).
fn ns_window_new(width f64, height f64, style u64, title str) *NSWindow {
    var raw *u8 = msg_id(objc_class(&cls_NSWindow, "NSWindow"), sel(&sel_alloc, "alloc"))
    var window *NSWindow = msg_id_dddduub(raw, sel(&sel_initWithContentRect_styleMask_backing_defer_, "initWithContentRect:styleMask:backing:defer:"),
        0.0, 0.0, width, height, style, NSBackingStoreBuffered, false)
    msg_void_b(window, sel(&sel_setReleasedWhenClosed_, "setReleasedWhenClosed:"), false)
    ns_set_title(window, title)
    msg_void(window, sel(&sel_center, "center"))
    window
}

// Sets the window title.
fn ns_set_title(window *NSWindow, title str) {
    text := ns_string(title)
    msg_void_p(window, sel(&sel_setTitle_, "setTitle:"), text)
    objc_release(text)
}

// Shows the window and gives it keyboard focus.
fn ns_make_key_and_order_front(window *NSWindow) { msg_void_p(window, sel(&sel_makeKeyAndOrderFront_, "makeKeyAndOrderFront:"), window) }

// False once the window has been closed (by the user or ns_close).
fn ns_is_visible(window *NSWindow) bool { msg_bool(window, sel(&sel_isVisible, "isVisible")) }

// Closes the window.
fn ns_close(window *NSWindow) { msg_void(window, sel(&sel_close, "close")) }

// The view that fills the window's content area.
fn ns_content_view(window *NSWindow) *NSView { msg_id(window, sel(&sel_contentView, "contentView")) }

// Pixels per point of the screen the window is on (2.0 on Retina displays).
fn ns_backing_scale_factor(window *NSWindow) f64 { msg_f64(window, sel(&sel_backingScaleFactor, "backingScaleFactor")) }

// Makes the view draw through a Metal layer (layer-hosting: the layer is set first, then wantsLayer).
fn ns_set_layer(view *NSView, layer *CAMetalLayer) {
    msg_void_p(view, sel(&sel_setLayer_, "setLayer:"), layer)
    msg_void_b(view, sel(&sel_setWantsLayer_, "setWantsLayer:"), true)
}

// ---- QuartzCore: CAMetalLayer ---------------------------------------------------------------
struct CAMetalLayer { isa *u8 }
struct CAMetalDrawable { isa *u8 }

var cls_CAMetalLayer *u8
var sel_setDevice_ *u8
var sel_setPixelFormat_ *u8
var sel_setFramebufferOnly_ *u8
var sel_setDrawableSize_ *u8
var sel_setContentsScale_ *u8
var sel_setDisplaySyncEnabled_ *u8
var sel_nextDrawable *u8
var sel_texture *u8

// A layer that provides drawable textures for a view (owned by the caller).
fn ca_metal_layer_new() *CAMetalLayer { objc_new(objc_class(&cls_CAMetalLayer, "CAMetalLayer")) }

// The device whose textures the layer hands out.
fn ca_set_device(layer *CAMetalLayer, device *MTLDevice) { msg_void_p(layer, sel(&sel_setDevice_, "setDevice:"), device) }

// Pixel format of the drawables (MTLPixelFormatBGRA8Unorm, ...).
fn ca_set_pixel_format(layer *CAMetalLayer, format u64) { msg_void_u(layer, sel(&sel_setPixelFormat_, "setPixelFormat:"), format) }

// True (the default): drawables may only be render targets, which lets the system present them faster.
fn ca_set_framebuffer_only(layer *CAMetalLayer, on bool) { msg_void_b(layer, sel(&sel_setFramebufferOnly_, "setFramebufferOnly:"), on) }

// Size of the drawables in pixels (a CGSize: two doubles).
fn ca_set_drawable_size(layer *CAMetalLayer, width f64, height f64) { msg_void_dd(layer, sel(&sel_setDrawableSize_, "setDrawableSize:"), width, height) }

// Pixels per point of the layer; use the window's backing scale factor.
fn ca_set_contents_scale(layer *CAMetalLayer, scale f64) { msg_void_d(layer, sel(&sel_setContentsScale_, "setContentsScale:"), scale) }

// Whether presentation waits for the display refresh (vsync).
fn ca_set_display_sync_enabled(layer *CAMetalLayer, on bool) { msg_void_b(layer, sel(&sel_setDisplaySyncEnabled_, "setDisplaySyncEnabled:"), on) }

// The next drawable to render into; blocks while all are in use, nil after a time-out (autoreleased).
fn ca_next_drawable(layer *CAMetalLayer) *CAMetalDrawable { msg_id(layer, sel(&sel_nextDrawable, "nextDrawable")) }

// The texture of a drawable: the colour attachment of the frame's render pass.
fn ca_texture(drawable *CAMetalDrawable) *MTLTexture { msg_id(drawable, sel(&sel_texture, "texture")) }

// ---- Metal: enumerations (all NSUInteger) ---------------------------------------------------
// MTLPixelFormat
const MTLPixelFormatInvalid u64 = 0
const MTLPixelFormatA8Unorm u64 = 1
const MTLPixelFormatR8Unorm u64 = 10
const MTLPixelFormatR8Unorm_sRGB u64 = 11
const MTLPixelFormatR8Snorm u64 = 12
const MTLPixelFormatR8Uint u64 = 13
const MTLPixelFormatR8Sint u64 = 14
const MTLPixelFormatR16Unorm u64 = 20
const MTLPixelFormatR16Snorm u64 = 22
const MTLPixelFormatR16Uint u64 = 23
const MTLPixelFormatR16Sint u64 = 24
const MTLPixelFormatR16Float u64 = 25
const MTLPixelFormatRG8Unorm u64 = 30
const MTLPixelFormatRG8Unorm_sRGB u64 = 31
const MTLPixelFormatRG8Snorm u64 = 32
const MTLPixelFormatRG8Uint u64 = 33
const MTLPixelFormatRG8Sint u64 = 34
const MTLPixelFormatB5G6R5Unorm u64 = 40
const MTLPixelFormatA1BGR5Unorm u64 = 41
const MTLPixelFormatABGR4Unorm u64 = 42
const MTLPixelFormatBGR5A1Unorm u64 = 43
const MTLPixelFormatR32Uint u64 = 53
const MTLPixelFormatR32Sint u64 = 54
const MTLPixelFormatR32Float u64 = 55
const MTLPixelFormatRG16Unorm u64 = 60
const MTLPixelFormatRG16Snorm u64 = 62
const MTLPixelFormatRG16Uint u64 = 63
const MTLPixelFormatRG16Sint u64 = 64
const MTLPixelFormatRG16Float u64 = 65
const MTLPixelFormatRGBA8Unorm u64 = 70
const MTLPixelFormatRGBA8Unorm_sRGB u64 = 71
const MTLPixelFormatRGBA8Snorm u64 = 72
const MTLPixelFormatRGBA8Uint u64 = 73
const MTLPixelFormatRGBA8Sint u64 = 74
const MTLPixelFormatBGRA8Unorm u64 = 80
const MTLPixelFormatBGRA8Unorm_sRGB u64 = 81
const MTLPixelFormatRGB10A2Unorm u64 = 90
const MTLPixelFormatRGB10A2Uint u64 = 91
const MTLPixelFormatRG11B10Float u64 = 92
const MTLPixelFormatRGB9E5Float u64 = 93
const MTLPixelFormatBGR10A2Unorm u64 = 94
const MTLPixelFormatRG32Uint u64 = 103
const MTLPixelFormatRG32Sint u64 = 104
const MTLPixelFormatRG32Float u64 = 105
const MTLPixelFormatRGBA16Unorm u64 = 110
const MTLPixelFormatRGBA16Snorm u64 = 112
const MTLPixelFormatRGBA16Uint u64 = 113
const MTLPixelFormatRGBA16Sint u64 = 114
const MTLPixelFormatRGBA16Float u64 = 115
const MTLPixelFormatRGBA32Uint u64 = 123
const MTLPixelFormatRGBA32Sint u64 = 124
const MTLPixelFormatRGBA32Float u64 = 125
const MTLPixelFormatBC1_RGBA u64 = 130
const MTLPixelFormatBC1_RGBA_sRGB u64 = 131
const MTLPixelFormatBC2_RGBA u64 = 132
const MTLPixelFormatBC2_RGBA_sRGB u64 = 133
const MTLPixelFormatBC3_RGBA u64 = 134
const MTLPixelFormatBC3_RGBA_sRGB u64 = 135
const MTLPixelFormatBC4_RUnorm u64 = 140
const MTLPixelFormatBC4_RSnorm u64 = 141
const MTLPixelFormatBC5_RGUnorm u64 = 142
const MTLPixelFormatBC5_RGSnorm u64 = 143
const MTLPixelFormatBC6H_RGBFloat u64 = 150
const MTLPixelFormatBC6H_RGBUfloat u64 = 151
const MTLPixelFormatBC7_RGBAUnorm u64 = 152
const MTLPixelFormatBC7_RGBAUnorm_sRGB u64 = 153
const MTLPixelFormatASTC_4x4_sRGB u64 = 186
const MTLPixelFormatASTC_8x8_sRGB u64 = 194
const MTLPixelFormatASTC_4x4_LDR u64 = 204
const MTLPixelFormatASTC_8x8_LDR u64 = 212
const MTLPixelFormatDepth16Unorm u64 = 250
const MTLPixelFormatDepth32Float u64 = 252
const MTLPixelFormatStencil8 u64 = 253
const MTLPixelFormatDepth24Unorm_Stencil8 u64 = 255
const MTLPixelFormatDepth32Float_Stencil8 u64 = 260
const MTLPixelFormatX32_Stencil8 u64 = 261
const MTLPixelFormatX24_Stencil8 u64 = 262
// MTLLoadAction
const MTLLoadActionDontCare u64 = 0
const MTLLoadActionLoad u64 = 1
const MTLLoadActionClear u64 = 2
// MTLStoreAction
const MTLStoreActionDontCare u64 = 0
const MTLStoreActionStore u64 = 1
const MTLStoreActionMultisampleResolve u64 = 2
const MTLStoreActionStoreAndMultisampleResolve u64 = 3
const MTLStoreActionUnknown u64 = 4
const MTLStoreActionCustomSampleDepthStore u64 = 5
// MTLPrimitiveType
const MTLPrimitiveTypePoint u64 = 0
const MTLPrimitiveTypeLine u64 = 1
const MTLPrimitiveTypeLineStrip u64 = 2
const MTLPrimitiveTypeTriangle u64 = 3
const MTLPrimitiveTypeTriangleStrip u64 = 4
// MTLIndexType
const MTLIndexTypeUInt16 u64 = 0
const MTLIndexTypeUInt32 u64 = 1
// MTLCullMode, MTLWinding, MTLTriangleFillMode
const MTLCullModeNone u64 = 0
const MTLCullModeFront u64 = 1
const MTLCullModeBack u64 = 2
const MTLWindingClockwise u64 = 0
const MTLWindingCounterClockwise u64 = 1
const MTLTriangleFillModeFill u64 = 0
const MTLTriangleFillModeLines u64 = 1
// MTLCompareFunction
const MTLCompareFunctionNever u64 = 0
const MTLCompareFunctionLess u64 = 1
const MTLCompareFunctionEqual u64 = 2
const MTLCompareFunctionLessEqual u64 = 3
const MTLCompareFunctionGreater u64 = 4
const MTLCompareFunctionNotEqual u64 = 5
const MTLCompareFunctionGreaterEqual u64 = 6
const MTLCompareFunctionAlways u64 = 7
// MTLStencilOperation
const MTLStencilOperationKeep u64 = 0
const MTLStencilOperationZero u64 = 1
const MTLStencilOperationReplace u64 = 2
const MTLStencilOperationIncrementClamp u64 = 3
const MTLStencilOperationDecrementClamp u64 = 4
const MTLStencilOperationInvert u64 = 5
const MTLStencilOperationIncrementWrap u64 = 6
const MTLStencilOperationDecrementWrap u64 = 7
// MTLBlendFactor
const MTLBlendFactorZero u64 = 0
const MTLBlendFactorOne u64 = 1
const MTLBlendFactorSourceColor u64 = 2
const MTLBlendFactorOneMinusSourceColor u64 = 3
const MTLBlendFactorSourceAlpha u64 = 4
const MTLBlendFactorOneMinusSourceAlpha u64 = 5
const MTLBlendFactorDestinationColor u64 = 6
const MTLBlendFactorOneMinusDestinationColor u64 = 7
const MTLBlendFactorDestinationAlpha u64 = 8
const MTLBlendFactorOneMinusDestinationAlpha u64 = 9
const MTLBlendFactorSourceAlphaSaturated u64 = 10
const MTLBlendFactorBlendColor u64 = 11
const MTLBlendFactorOneMinusBlendColor u64 = 12
const MTLBlendFactorBlendAlpha u64 = 13
const MTLBlendFactorOneMinusBlendAlpha u64 = 14
// MTLBlendOperation
const MTLBlendOperationAdd u64 = 0
const MTLBlendOperationSubtract u64 = 1
const MTLBlendOperationReverseSubtract u64 = 2
const MTLBlendOperationMin u64 = 3
const MTLBlendOperationMax u64 = 4
// MTLColorWriteMask (bits)
const MTLColorWriteMaskNone u64 = 0
const MTLColorWriteMaskAlpha u64 = 1
const MTLColorWriteMaskBlue u64 = 2
const MTLColorWriteMaskGreen u64 = 4
const MTLColorWriteMaskRed u64 = 8
const MTLColorWriteMaskAll u64 = 15
// MTLVertexFormat
const MTLVertexFormatInvalid u64 = 0
const MTLVertexFormatUChar2 u64 = 1
const MTLVertexFormatUChar3 u64 = 2
const MTLVertexFormatUChar4 u64 = 3
const MTLVertexFormatChar2 u64 = 4
const MTLVertexFormatChar3 u64 = 5
const MTLVertexFormatChar4 u64 = 6
const MTLVertexFormatUChar2Normalized u64 = 7
const MTLVertexFormatUChar3Normalized u64 = 8
const MTLVertexFormatUChar4Normalized u64 = 9
const MTLVertexFormatChar2Normalized u64 = 10
const MTLVertexFormatChar3Normalized u64 = 11
const MTLVertexFormatChar4Normalized u64 = 12
const MTLVertexFormatUShort2 u64 = 13
const MTLVertexFormatUShort3 u64 = 14
const MTLVertexFormatUShort4 u64 = 15
const MTLVertexFormatShort2 u64 = 16
const MTLVertexFormatShort3 u64 = 17
const MTLVertexFormatShort4 u64 = 18
const MTLVertexFormatUShort2Normalized u64 = 19
const MTLVertexFormatUShort3Normalized u64 = 20
const MTLVertexFormatUShort4Normalized u64 = 21
const MTLVertexFormatShort2Normalized u64 = 22
const MTLVertexFormatShort3Normalized u64 = 23
const MTLVertexFormatShort4Normalized u64 = 24
const MTLVertexFormatHalf2 u64 = 25
const MTLVertexFormatHalf3 u64 = 26
const MTLVertexFormatHalf4 u64 = 27
const MTLVertexFormatFloat u64 = 28
const MTLVertexFormatFloat2 u64 = 29
const MTLVertexFormatFloat3 u64 = 30
const MTLVertexFormatFloat4 u64 = 31
const MTLVertexFormatInt u64 = 32
const MTLVertexFormatInt2 u64 = 33
const MTLVertexFormatInt3 u64 = 34
const MTLVertexFormatInt4 u64 = 35
const MTLVertexFormatUInt u64 = 36
const MTLVertexFormatUInt2 u64 = 37
const MTLVertexFormatUInt3 u64 = 38
const MTLVertexFormatUInt4 u64 = 39
const MTLVertexFormatInt1010102Normalized u64 = 40
const MTLVertexFormatUInt1010102Normalized u64 = 41
const MTLVertexFormatUChar4Normalized_BGRA u64 = 42
const MTLVertexFormatUChar u64 = 45
const MTLVertexFormatChar u64 = 46
const MTLVertexFormatUCharNormalized u64 = 47
const MTLVertexFormatCharNormalized u64 = 48
const MTLVertexFormatUShort u64 = 49
const MTLVertexFormatShort u64 = 50
const MTLVertexFormatUShortNormalized u64 = 51
const MTLVertexFormatShortNormalized u64 = 52
const MTLVertexFormatHalf u64 = 53
// MTLVertexStepFunction
const MTLVertexStepFunctionConstant u64 = 0
const MTLVertexStepFunctionPerVertex u64 = 1
const MTLVertexStepFunctionPerInstance u64 = 2
// MTLResourceOptions (bits): CPU cache mode | storage mode << 4 | hazard tracking mode << 8
const MTLResourceCPUCacheModeDefaultCache u64 = 0
const MTLResourceCPUCacheModeWriteCombined u64 = 1
const MTLResourceStorageModeShared u64 = 0
const MTLResourceStorageModeManaged u64 = 16
const MTLResourceStorageModePrivate u64 = 32
const MTLResourceStorageModeMemoryless u64 = 48
const MTLResourceHazardTrackingModeUntracked u64 = 256
const MTLResourceHazardTrackingModeTracked u64 = 512
// MTLStorageMode
const MTLStorageModeShared u64 = 0
const MTLStorageModeManaged u64 = 1
const MTLStorageModePrivate u64 = 2
const MTLStorageModeMemoryless u64 = 3
// MTLTextureType
const MTLTextureType1D u64 = 0
const MTLTextureType1DArray u64 = 1
const MTLTextureType2D u64 = 2
const MTLTextureType2DArray u64 = 3
const MTLTextureType2DMultisample u64 = 4
const MTLTextureTypeCube u64 = 5
const MTLTextureTypeCubeArray u64 = 6
const MTLTextureType3D u64 = 7
// MTLTextureUsage (bits)
const MTLTextureUsageUnknown u64 = 0
const MTLTextureUsageShaderRead u64 = 1
const MTLTextureUsageShaderWrite u64 = 2
const MTLTextureUsageRenderTarget u64 = 4
const MTLTextureUsagePixelFormatView u64 = 16
// MTLSamplerMinMagFilter, MTLSamplerMipFilter, MTLSamplerAddressMode
const MTLSamplerMinMagFilterNearest u64 = 0
const MTLSamplerMinMagFilterLinear u64 = 1
const MTLSamplerMipFilterNotMipmapped u64 = 0
const MTLSamplerMipFilterNearest u64 = 1
const MTLSamplerMipFilterLinear u64 = 2
const MTLSamplerAddressModeClampToEdge u64 = 0
const MTLSamplerAddressModeMirrorClampToEdge u64 = 1
const MTLSamplerAddressModeRepeat u64 = 2
const MTLSamplerAddressModeMirrorRepeat u64 = 3
const MTLSamplerAddressModeClampToZero u64 = 4
const MTLSamplerAddressModeClampToBorderColor u64 = 5
// MTLCommandBufferStatus
const MTLCommandBufferStatusNotEnqueued u64 = 0
const MTLCommandBufferStatusEnqueued u64 = 1
const MTLCommandBufferStatusCommitted u64 = 2
const MTLCommandBufferStatusScheduled u64 = 3
const MTLCommandBufferStatusCompleted u64 = 4
const MTLCommandBufferStatusError u64 = 5

// ---- Metal: C structs -----------------------------------------------------------------------
// Objective-C passes these BY VALUE. The wrappers below take them by value too and lower the
// call the way the arm64 (Apple silicon) ABI does: a struct of up to four doubles travels as
// that many floating-point arguments, any other struct larger than 16 bytes as a pointer to a
// copy. On x86-64 macOS the structs larger than 16 bytes are copied onto the stack instead,
// so a backend for that target has to lower these calls itself (listed in docs/std/metal.md).

// 24 bytes; pointer to a copy.
struct MTLOrigin { x u64, y u64, z u64 }
// 24 bytes; pointer to a copy.
struct MTLSize { width u64, height u64, depth u64 }
// 48 bytes; pointer to a copy.
struct MTLRegion { origin MTLOrigin, size MTLSize }
// 32 bytes, four doubles; four floating-point arguments.
struct MTLClearColor { red f64, green f64, blue f64, alpha f64 }
// 48 bytes, six doubles; pointer to a copy.
struct MTLViewport { originX f64, originY f64, width f64, height f64, znear f64, zfar f64 }
// 32 bytes; pointer to a copy.
struct MTLScissorRect { x u64, y u64, width u64, height u64 }

// The region of a 2D texture (or of one mip level) starting at (x, y).
fn mtl_region_2d(x u64, y u64, width u64, height u64) MTLRegion { MTLRegion{MTLOrigin{x, y, 0}, MTLSize{width, height, 1}} }

// ---- Metal: objects -------------------------------------------------------------------------
struct MTLDevice { isa *u8 }
struct MTLCommandQueue { isa *u8 }
struct MTLCommandBuffer { isa *u8 }
struct MTLRenderCommandEncoder { isa *u8 }
struct MTLBlitCommandEncoder { isa *u8 }
struct MTLComputeCommandEncoder { isa *u8 }
struct MTLBuffer { isa *u8 }
struct MTLTexture { isa *u8 }
struct MTLSamplerState { isa *u8 }
struct MTLDepthStencilState { isa *u8 }
struct MTLLibrary { isa *u8 }
struct MTLFunction { isa *u8 }
struct MTLRenderPipelineState { isa *u8 }
struct MTLComputePipelineState { isa *u8 }
struct MTLTextureDescriptor { isa *u8 }
struct MTLSamplerDescriptor { isa *u8 }
struct MTLDepthStencilDescriptor { isa *u8 }
struct MTLStencilDescriptor { isa *u8 }
struct MTLVertexDescriptor { isa *u8 }
struct MTLRenderPipelineDescriptor { isa *u8 }
struct MTLRenderPipelineColorAttachmentDescriptor { isa *u8 }
struct MTLRenderPassDescriptor { isa *u8 }
// A colour, depth or stencil attachment of a render pass (they share one base class).
struct MTLRenderPassAttachmentDescriptor { isa *u8 }

var sel_setLabel_ *u8
var sel_objectAtIndexedSubscript_ *u8

// Names an object (device objects, descriptors, command buffers, encoders) for debuggers and error messages.
fn mtl_set_label[T](obj *T, label str) {
    text := ns_string(label)
    msg_void_p(obj, sel(&sel_setLabel_, "setLabel:"), text)
    objc_release(text)
}

// ---- MTLDevice
var sel_name *u8
var sel_newCommandQueue *u8
var sel_newBufferWithLength_options_ *u8
var sel_newBufferWithBytes_length_options_ *u8
var sel_newTextureWithDescriptor_ *u8
var sel_newSamplerStateWithDescriptor_ *u8
var sel_newDepthStencilStateWithDescriptor_ *u8
var sel_newLibraryWithSource_options_error_ *u8
var sel_newDefaultLibrary *u8
var sel_newFunctionWithName_ *u8
var sel_newRenderPipelineStateWithDescriptor_error_ *u8
var sel_newComputePipelineStateWithFunction_error_ *u8
var sel_supportsTextureSampleCount_ *u8

// The preferred GPU, or nil if Metal is not available (owned by the caller).
fn mtl_create_system_default_device() *MTLDevice { cast[*MTLDevice](MTLCreateSystemDefaultDevice()) }

// The device's name, e.g. "Apple M2".
fn mtl_name(device *MTLDevice) str {
    var text *NSString = msg_id(device, sel(&sel_name, "name"))
    ns_string_text(text)
}

// A queue that executes command buffers in order.
fn mtl_new_command_queue(device *MTLDevice) *MTLCommandQueue { msg_id(device, sel(&sel_newCommandQueue, "newCommandQueue")) }

// A zero-filled buffer of `length` bytes; `options` are MTLResource* bits.
fn mtl_new_buffer_with_length(device *MTLDevice, length u64, options u64) *MTLBuffer {
    msg_id_uu(device, sel(&sel_newBufferWithLength_options_, "newBufferWithLength:options:"), length, options)
}

// A buffer initialised with a copy of `length` bytes.
fn mtl_new_buffer_with_bytes(device *MTLDevice, bytes *u8, length u64, options u64) *MTLBuffer {
    msg_id_puu(device, sel(&sel_newBufferWithBytes_length_options_, "newBufferWithBytes:length:options:"), bytes, length, options)
}

// A texture as described; nil if the description is invalid.
fn mtl_new_texture_with_descriptor(device *MTLDevice, descriptor *MTLTextureDescriptor) *MTLTexture {
    msg_id_p(device, sel(&sel_newTextureWithDescriptor_, "newTextureWithDescriptor:"), descriptor)
}

// An immutable sampler.
fn mtl_new_sampler_state_with_descriptor(device *MTLDevice, descriptor *MTLSamplerDescriptor) *MTLSamplerState {
    msg_id_p(device, sel(&sel_newSamplerStateWithDescriptor_, "newSamplerStateWithDescriptor:"), descriptor)
}

// An immutable depth/stencil test configuration.
fn mtl_new_depth_stencil_state_with_descriptor(device *MTLDevice, descriptor *MTLDepthStencilDescriptor) *MTLDepthStencilState {
    msg_id_p(device, sel(&sel_newDepthStencilStateWithDescriptor_, "newDepthStencilStateWithDescriptor:"), descriptor)
}

// Compiles Metal Shading Language source with default options. Returns nil and stores the reason in `*error` (if not nil) on failure.
fn mtl_new_library_with_source(device *MTLDevice, source str, error **NSError) *MTLLibrary {
    text := ns_string(source)
    var options *u8
    var library *MTLLibrary = msg_id_ppp(device, sel(&sel_newLibraryWithSource_options_error_, "newLibraryWithSource:options:error:"), text, options, error)
    objc_release(text)
    library
}

// The library compiled into the application bundle (default.metallib); nil if there is none.
fn mtl_new_default_library(device *MTLDevice) *MTLLibrary { msg_id(device, sel(&sel_newDefaultLibrary, "newDefaultLibrary")) }

// The shader function `name` of a library; nil if it does not exist.
fn mtl_new_function_with_name(library *MTLLibrary, name str) *MTLFunction {
    text := ns_string(name)
    var function *MTLFunction = msg_id_p(library, sel(&sel_newFunctionWithName_, "newFunctionWithName:"), text)
    objc_release(text)
    function
}

// Builds a render pipeline. Returns nil and stores the reason in `*error` (if not nil) on failure.
fn mtl_new_render_pipeline_state_with_descriptor(device *MTLDevice, descriptor *MTLRenderPipelineDescriptor, error **NSError) *MTLRenderPipelineState {
    msg_id_pp(device, sel(&sel_newRenderPipelineStateWithDescriptor_error_, "newRenderPipelineStateWithDescriptor:error:"), descriptor, error)
}

// Builds a compute pipeline from a kernel function. Returns nil and stores the reason in `*error` (if not nil) on failure.
fn mtl_new_compute_pipeline_state_with_function(device *MTLDevice, function *MTLFunction, error **NSError) *MTLComputePipelineState {
    msg_id_pp(device, sel(&sel_newComputePipelineStateWithFunction_error_, "newComputePipelineStateWithFunction:error:"), function, error)
}

// Whether multisample textures with this many samples per pixel can be created.
fn mtl_supports_texture_sample_count(device *MTLDevice, count u64) bool {
    msg_bool_u(device, sel(&sel_supportsTextureSampleCount_, "supportsTextureSampleCount:"), count)
}

// ---- MTLBuffer
var sel_contents *u8
var sel_length *u8
var sel_didModifyRange_ *u8

// The buffer's memory (shared and managed storage modes; nil for private).
fn mtl_contents(buffer *MTLBuffer) *u8 { msg_id(buffer, sel(&sel_contents, "contents")) }

// Size of the buffer in bytes.
fn mtl_length(buffer *MTLBuffer) u64 { msg_u64(buffer, sel(&sel_length, "length")) }

// Tells Metal that the CPU changed `length` bytes at `location` of a managed-storage buffer (an NSRange: two integers).
fn mtl_did_modify_range(buffer *MTLBuffer, location u64, length u64) { msg_void_uu(buffer, sel(&sel_didModifyRange_, "didModifyRange:"), location, length) }

// ---- MTLTextureDescriptor, MTLTexture
var cls_MTLTextureDescriptor *u8
var sel_texture2DDescriptorWithPixelFormat_width_height_mipmapped_ *u8
var sel_setTextureType_ *u8
var sel_setWidth_ *u8
var sel_setHeight_ *u8
var sel_setDepth_ *u8
var sel_setMipmapLevelCount_ *u8
var sel_setSampleCount_ *u8
var sel_setArrayLength_ *u8
var sel_setUsage_ *u8
var sel_setStorageMode_ *u8
var sel_width *u8
var sel_height *u8
var sel_pixelFormat *u8
var sel_replaceRegion_mipmapLevel_withBytes_bytesPerRow_ *u8
var sel_getBytes_bytesPerRow_fromRegion_mipmapLevel_ *u8

// A descriptor for a 2D texture; `mipmapped` asks for a full mip chain (autoreleased).
fn mtl_texture_2d_descriptor_with_pixel_format(format u64, width u64, height u64, mipmapped bool) *MTLTextureDescriptor {
    msg_id_uuub(objc_class(&cls_MTLTextureDescriptor, "MTLTextureDescriptor"),
        sel(&sel_texture2DDescriptorWithPixelFormat_width_height_mipmapped_, "texture2DDescriptorWithPixelFormat:width:height:mipmapped:"), format, width, height, mipmapped)
}

// Dimensionality and arrangement (MTLTextureType2D, ...).
fn mtl_set_texture_type(descriptor *MTLTextureDescriptor, kind u64) { msg_void_u(descriptor, sel(&sel_setTextureType_, "setTextureType:"), kind) }

// Pixel format of the texture.
fn mtl_set_pixel_format(descriptor *MTLTextureDescriptor, format u64) { msg_void_u(descriptor, sel(&sel_setPixelFormat_, "setPixelFormat:"), format) }

// Width of the base level in pixels.
fn mtl_set_width(descriptor *MTLTextureDescriptor, width u64) { msg_void_u(descriptor, sel(&sel_setWidth_, "setWidth:"), width) }

// Height of the base level in pixels.
fn mtl_set_height(descriptor *MTLTextureDescriptor, height u64) { msg_void_u(descriptor, sel(&sel_setHeight_, "setHeight:"), height) }

// Depth of a 3D texture.
fn mtl_set_depth(descriptor *MTLTextureDescriptor, depth u64) { msg_void_u(descriptor, sel(&sel_setDepth_, "setDepth:"), depth) }

// Number of mip levels.
fn mtl_set_mipmap_level_count(descriptor *MTLTextureDescriptor, count u64) { msg_void_u(descriptor, sel(&sel_setMipmapLevelCount_, "setMipmapLevelCount:"), count) }

// Samples per pixel of a multisample texture.
fn mtl_set_sample_count(descriptor *MTLTextureDescriptor, count u64) { msg_void_u(descriptor, sel(&sel_setSampleCount_, "setSampleCount:"), count) }

// Number of slices of an array texture.
fn mtl_set_array_length(descriptor *MTLTextureDescriptor, length u64) { msg_void_u(descriptor, sel(&sel_setArrayLength_, "setArrayLength:"), length) }

// How the texture will be used (MTLTextureUsage* bits); render targets need MTLTextureUsageRenderTarget.
fn mtl_set_usage(descriptor *MTLTextureDescriptor, usage u64) { msg_void_u(descriptor, sel(&sel_setUsage_, "setUsage:"), usage) }

// Where the texture's memory lives (MTLStorageModePrivate for render targets).
fn mtl_set_storage_mode(descriptor *MTLTextureDescriptor, mode u64) { msg_void_u(descriptor, sel(&sel_setStorageMode_, "setStorageMode:"), mode) }

// Width of the base level in pixels.
fn mtl_width(texture *MTLTexture) u64 { msg_u64(texture, sel(&sel_width, "width")) }

// Height of the base level in pixels.
fn mtl_height(texture *MTLTexture) u64 { msg_u64(texture, sel(&sel_height, "height")) }

// Pixel format of the texture.
fn mtl_pixel_format(texture *MTLTexture) u64 { msg_u64(texture, sel(&sel_pixelFormat, "pixelFormat")) }

// Copies pixels from memory into a region of one mip level (slice 0).
fn mtl_replace_region(texture *MTLTexture, region MTLRegion, level u64, bytes *u8, bytes_per_row u64) {
    msg_void_pupu(texture, sel(&sel_replaceRegion_mipmapLevel_withBytes_bytesPerRow_, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:"), &region, level, bytes, bytes_per_row)
}

// Copies a region of one mip level (slice 0) into memory.
fn mtl_get_bytes(texture *MTLTexture, bytes *u8, bytes_per_row u64, region MTLRegion, level u64) {
    msg_void_pupu(texture, sel(&sel_getBytes_bytesPerRow_fromRegion_mipmapLevel_, "getBytes:bytesPerRow:fromRegion:mipmapLevel:"), bytes, bytes_per_row, &region, level)
}

// ---- MTLSamplerDescriptor
var cls_MTLSamplerDescriptor *u8
var sel_setMinFilter_ *u8
var sel_setMagFilter_ *u8
var sel_setMipFilter_ *u8
var sel_setSAddressMode_ *u8
var sel_setTAddressMode_ *u8
var sel_setRAddressMode_ *u8
var sel_setMaxAnisotropy_ *u8
var sel_setCompareFunction_ *u8

// A sampler descriptor with the defaults: nearest filtering, clamp to edge (owned by the caller).
fn mtl_sampler_descriptor_new() *MTLSamplerDescriptor { objc_new(objc_class(&cls_MTLSamplerDescriptor, "MTLSamplerDescriptor")) }

// Filter used when the texture is minified (MTLSamplerMinMagFilter*).
fn mtl_set_min_filter(descriptor *MTLSamplerDescriptor, filter u64) { msg_void_u(descriptor, sel(&sel_setMinFilter_, "setMinFilter:"), filter) }

// Filter used when the texture is magnified (MTLSamplerMinMagFilter*).
fn mtl_set_mag_filter(descriptor *MTLSamplerDescriptor, filter u64) { msg_void_u(descriptor, sel(&sel_setMagFilter_, "setMagFilter:"), filter) }

// Filter between mip levels (MTLSamplerMipFilter*).
fn mtl_set_mip_filter(descriptor *MTLSamplerDescriptor, filter u64) { msg_void_u(descriptor, sel(&sel_setMipFilter_, "setMipFilter:"), filter) }

// Addressing outside [0, 1] along s, t and r (MTLSamplerAddressMode*).
fn mtl_set_address_modes(descriptor *MTLSamplerDescriptor, s u64, t u64, r u64) {
    msg_void_u(descriptor, sel(&sel_setSAddressMode_, "setSAddressMode:"), s)
    msg_void_u(descriptor, sel(&sel_setTAddressMode_, "setTAddressMode:"), t)
    msg_void_u(descriptor, sel(&sel_setRAddressMode_, "setRAddressMode:"), r)
}

// Maximum anisotropic samples (1 to 16).
fn mtl_set_max_anisotropy(descriptor *MTLSamplerDescriptor, samples u64) { msg_void_u(descriptor, sel(&sel_setMaxAnisotropy_, "setMaxAnisotropy:"), samples) }

// Comparison used by depth-comparison (shadow) sampling.
fn mtl_set_compare_function(descriptor *MTLSamplerDescriptor, function u64) { msg_void_u(descriptor, sel(&sel_setCompareFunction_, "setCompareFunction:"), function) }

// ---- MTLDepthStencilDescriptor, MTLStencilDescriptor
var cls_MTLDepthStencilDescriptor *u8
var cls_MTLStencilDescriptor *u8
var sel_setDepthCompareFunction_ *u8
var sel_setDepthWriteEnabled_ *u8
var sel_setFrontFaceStencil_ *u8
var sel_setBackFaceStencil_ *u8
var sel_setStencilCompareFunction_ *u8
var sel_setStencilFailureOperation_ *u8
var sel_setDepthFailureOperation_ *u8
var sel_setDepthStencilPassOperation_ *u8
var sel_setReadMask_ *u8
var sel_setWriteMask_ *u8

// A depth/stencil descriptor with the defaults: always pass, no depth writes (owned by the caller).
fn mtl_depth_stencil_descriptor_new() *MTLDepthStencilDescriptor { objc_new(objc_class(&cls_MTLDepthStencilDescriptor, "MTLDepthStencilDescriptor")) }

// Comparison between a fragment's depth and the stored depth (MTLCompareFunction*).
fn mtl_set_depth_compare_function(descriptor *MTLDepthStencilDescriptor, function u64) { msg_void_u(descriptor, sel(&sel_setDepthCompareFunction_, "setDepthCompareFunction:"), function) }

// Whether passing fragments write their depth.
fn mtl_set_depth_write_enabled(descriptor *MTLDepthStencilDescriptor, on bool) { msg_void_b(descriptor, sel(&sel_setDepthWriteEnabled_, "setDepthWriteEnabled:"), on) }

// Stencil test for front-facing primitives (nil disables it).
fn mtl_set_front_face_stencil(descriptor *MTLDepthStencilDescriptor, stencil *MTLStencilDescriptor) { msg_void_p(descriptor, sel(&sel_setFrontFaceStencil_, "setFrontFaceStencil:"), stencil) }

// Stencil test for back-facing primitives (nil disables it).
fn mtl_set_back_face_stencil(descriptor *MTLDepthStencilDescriptor, stencil *MTLStencilDescriptor) { msg_void_p(descriptor, sel(&sel_setBackFaceStencil_, "setBackFaceStencil:"), stencil) }

// A stencil descriptor with the defaults: always pass, keep (owned by the caller).
fn mtl_stencil_descriptor_new() *MTLStencilDescriptor { objc_new(objc_class(&cls_MTLStencilDescriptor, "MTLStencilDescriptor")) }

// Comparison between the reference value and the stored stencil value.
fn mtl_set_stencil_compare_function(descriptor *MTLStencilDescriptor, function u64) { msg_void_u(descriptor, sel(&sel_setStencilCompareFunction_, "setStencilCompareFunction:"), function) }

// What happens to the stored value when the stencil test fails, the depth test fails, or both pass (MTLStencilOperation*).
fn mtl_set_stencil_operations(descriptor *MTLStencilDescriptor, stencil_fail u64, depth_fail u64, pass u64) {
    msg_void_u(descriptor, sel(&sel_setStencilFailureOperation_, "setStencilFailureOperation:"), stencil_fail)
    msg_void_u(descriptor, sel(&sel_setDepthFailureOperation_, "setDepthFailureOperation:"), depth_fail)
    msg_void_u(descriptor, sel(&sel_setDepthStencilPassOperation_, "setDepthStencilPassOperation:"), pass)
}

// Bits of the stencil value that take part in the comparison and that may be written.
fn mtl_set_stencil_masks(descriptor *MTLStencilDescriptor, read u32, write u32) {
    msg_void_u(descriptor, sel(&sel_setReadMask_, "setReadMask:"), u64(read))
    msg_void_u(descriptor, sel(&sel_setWriteMask_, "setWriteMask:"), u64(write))
}

// ---- MTLVertexDescriptor
var cls_MTLVertexDescriptor *u8
var sel_vertexDescriptor *u8
var sel_attributes *u8
var sel_layouts *u8
var sel_setFormat_ *u8
var sel_setOffset_ *u8
var sel_setBufferIndex_ *u8
var sel_setStride_ *u8
var sel_setStepFunction_ *u8
var sel_setStepRate_ *u8

// An empty vertex descriptor (autoreleased).
fn mtl_vertex_descriptor() *MTLVertexDescriptor { msg_id(objc_class(&cls_MTLVertexDescriptor, "MTLVertexDescriptor"), sel(&sel_vertexDescriptor, "vertexDescriptor")) }

// Describes vertex attribute `index` (`[[attribute(index)]]` in the shader): its format, byte offset in the vertex and the buffer slot it is read from.
fn mtl_set_attribute(descriptor *MTLVertexDescriptor, index u64, format u64, offset u64, buffer_index u64) {
    var list *u8 = msg_id(descriptor, sel(&sel_attributes, "attributes"))
    var attribute *u8 = msg_id_u(list, sel(&sel_objectAtIndexedSubscript_, "objectAtIndexedSubscript:"), index)
    msg_void_u(attribute, sel(&sel_setFormat_, "setFormat:"), format)
    msg_void_u(attribute, sel(&sel_setOffset_, "setOffset:"), offset)
    msg_void_u(attribute, sel(&sel_setBufferIndex_, "setBufferIndex:"), buffer_index)
}

// Describes the buffer in slot `index`: bytes between vertices and how often to advance (MTLVertexStepFunction*, every `step_rate` instances).
fn mtl_set_layout(descriptor *MTLVertexDescriptor, index u64, stride u64, step_function u64, step_rate u64) {
    var list *u8 = msg_id(descriptor, sel(&sel_layouts, "layouts"))
    var layout *u8 = msg_id_u(list, sel(&sel_objectAtIndexedSubscript_, "objectAtIndexedSubscript:"), index)
    msg_void_u(layout, sel(&sel_setStride_, "setStride:"), stride)
    msg_void_u(layout, sel(&sel_setStepFunction_, "setStepFunction:"), step_function)
    msg_void_u(layout, sel(&sel_setStepRate_, "setStepRate:"), step_rate)
}

// ---- MTLRenderPipelineDescriptor
var cls_MTLRenderPipelineDescriptor *u8
var sel_setVertexFunction_ *u8
var sel_setFragmentFunction_ *u8
var sel_setVertexDescriptor_ *u8
var sel_setRasterSampleCount_ *u8
var sel_setDepthAttachmentPixelFormat_ *u8
var sel_setStencilAttachmentPixelFormat_ *u8
var sel_colorAttachments *u8
var sel_setBlendingEnabled_ *u8
var sel_setRgbBlendOperation_ *u8
var sel_setAlphaBlendOperation_ *u8
var sel_setSourceRGBBlendFactor_ *u8
var sel_setSourceAlphaBlendFactor_ *u8
var sel_setDestinationRGBBlendFactor_ *u8
var sel_setDestinationAlphaBlendFactor_ *u8

// An empty render pipeline descriptor (owned by the caller).
fn mtl_render_pipeline_descriptor_new() *MTLRenderPipelineDescriptor { objc_new(objc_class(&cls_MTLRenderPipelineDescriptor, "MTLRenderPipelineDescriptor")) }

// The vertex shader.
fn mtl_set_vertex_function(descriptor *MTLRenderPipelineDescriptor, function *MTLFunction) { msg_void_p(descriptor, sel(&sel_setVertexFunction_, "setVertexFunction:"), function) }

// The fragment shader.
fn mtl_set_fragment_function(descriptor *MTLRenderPipelineDescriptor, function *MTLFunction) { msg_void_p(descriptor, sel(&sel_setFragmentFunction_, "setFragmentFunction:"), function) }

// How vertex buffers map to the vertex shader's `[[stage_in]]` attributes.
fn mtl_set_vertex_descriptor(descriptor *MTLRenderPipelineDescriptor, vertices *MTLVertexDescriptor) { msg_void_p(descriptor, sel(&sel_setVertexDescriptor_, "setVertexDescriptor:"), vertices) }

// Samples per pixel of the render targets (1: no multisampling).
fn mtl_set_raster_sample_count(descriptor *MTLRenderPipelineDescriptor, count u64) { msg_void_u(descriptor, sel(&sel_setRasterSampleCount_, "setRasterSampleCount:"), count) }

// Pixel format of the depth attachment the pipeline renders to (MTLPixelFormatInvalid: none).
fn mtl_set_depth_attachment_pixel_format(descriptor *MTLRenderPipelineDescriptor, format u64) { msg_void_u(descriptor, sel(&sel_setDepthAttachmentPixelFormat_, "setDepthAttachmentPixelFormat:"), format) }

// Pixel format of the stencil attachment the pipeline renders to (MTLPixelFormatInvalid: none).
fn mtl_set_stencil_attachment_pixel_format(descriptor *MTLRenderPipelineDescriptor, format u64) { msg_void_u(descriptor, sel(&sel_setStencilAttachmentPixelFormat_, "setStencilAttachmentPixelFormat:"), format) }

// Colour attachment `index` of the pipeline: `descriptor.colorAttachments[index]`.
fn mtl_color_attachment(descriptor *MTLRenderPipelineDescriptor, index u64) *MTLRenderPipelineColorAttachmentDescriptor {
    var list *u8 = msg_id(descriptor, sel(&sel_colorAttachments, "colorAttachments"))
    msg_id_u(list, sel(&sel_objectAtIndexedSubscript_, "objectAtIndexedSubscript:"), index)
}

// Pixel format of the texture this attachment renders to; must match the render pass.
fn mtl_set_pixel_format(attachment *MTLRenderPipelineColorAttachmentDescriptor, format u64) { msg_void_u(attachment, sel(&sel_setPixelFormat_, "setPixelFormat:"), format) }

// Turns blending on or off (off: the fragment colour replaces the stored colour).
fn mtl_set_blending_enabled(attachment *MTLRenderPipelineColorAttachmentDescriptor, on bool) { msg_void_b(attachment, sel(&sel_setBlendingEnabled_, "setBlendingEnabled:"), on) }

// How source and destination are combined for colour and for alpha (MTLBlendOperation*).
fn mtl_set_blend_operations(attachment *MTLRenderPipelineColorAttachmentDescriptor, rgb u64, alpha u64) {
    msg_void_u(attachment, sel(&sel_setRgbBlendOperation_, "setRgbBlendOperation:"), rgb)
    msg_void_u(attachment, sel(&sel_setAlphaBlendOperation_, "setAlphaBlendOperation:"), alpha)
}

// Factors applied to the fragment's colour and alpha before blending (MTLBlendFactor*).
fn mtl_set_source_blend_factors(attachment *MTLRenderPipelineColorAttachmentDescriptor, rgb u64, alpha u64) {
    msg_void_u(attachment, sel(&sel_setSourceRGBBlendFactor_, "setSourceRGBBlendFactor:"), rgb)
    msg_void_u(attachment, sel(&sel_setSourceAlphaBlendFactor_, "setSourceAlphaBlendFactor:"), alpha)
}

// Factors applied to the stored colour and alpha before blending (MTLBlendFactor*).
fn mtl_set_destination_blend_factors(attachment *MTLRenderPipelineColorAttachmentDescriptor, rgb u64, alpha u64) {
    msg_void_u(attachment, sel(&sel_setDestinationRGBBlendFactor_, "setDestinationRGBBlendFactor:"), rgb)
    msg_void_u(attachment, sel(&sel_setDestinationAlphaBlendFactor_, "setDestinationAlphaBlendFactor:"), alpha)
}

// Channels that may be written (MTLColorWriteMask* bits).
fn mtl_set_write_mask(attachment *MTLRenderPipelineColorAttachmentDescriptor, mask u64) { msg_void_u(attachment, sel(&sel_setWriteMask_, "setWriteMask:"), mask) }

// ---- MTLRenderPassDescriptor
var cls_MTLRenderPassDescriptor *u8
var sel_renderPassDescriptor *u8
var sel_depthAttachment *u8
var sel_stencilAttachment *u8
var sel_setTexture_ *u8
var sel_setLevel_ *u8
var sel_setSlice_ *u8
var sel_setResolveTexture_ *u8
var sel_setLoadAction_ *u8
var sel_setStoreAction_ *u8
var sel_setClearColor_ *u8
var sel_setClearDepth_ *u8
var sel_setClearStencil_ *u8

// An empty render pass descriptor (autoreleased); build one per frame.
fn mtl_render_pass_descriptor() *MTLRenderPassDescriptor {
    msg_id(objc_class(&cls_MTLRenderPassDescriptor, "MTLRenderPassDescriptor"), sel(&sel_renderPassDescriptor, "renderPassDescriptor"))
}

// Colour attachment `index` of the pass: `descriptor.colorAttachments[index]`.
fn mtl_color_attachment(descriptor *MTLRenderPassDescriptor, index u64) *MTLRenderPassAttachmentDescriptor {
    var list *u8 = msg_id(descriptor, sel(&sel_colorAttachments, "colorAttachments"))
    msg_id_u(list, sel(&sel_objectAtIndexedSubscript_, "objectAtIndexedSubscript:"), index)
}

// The depth attachment of the pass.
fn mtl_depth_attachment(descriptor *MTLRenderPassDescriptor) *MTLRenderPassAttachmentDescriptor { msg_id(descriptor, sel(&sel_depthAttachment, "depthAttachment")) }

// The stencil attachment of the pass.
fn mtl_stencil_attachment(descriptor *MTLRenderPassDescriptor) *MTLRenderPassAttachmentDescriptor { msg_id(descriptor, sel(&sel_stencilAttachment, "stencilAttachment")) }

// The texture the attachment renders to.
fn mtl_set_texture(attachment *MTLRenderPassAttachmentDescriptor, texture *MTLTexture) { msg_void_p(attachment, sel(&sel_setTexture_, "setTexture:"), texture) }

// Mip level of the texture to render to.
fn mtl_set_level(attachment *MTLRenderPassAttachmentDescriptor, level u64) { msg_void_u(attachment, sel(&sel_setLevel_, "setLevel:"), level) }

// Array slice or cube face of the texture to render to.
fn mtl_set_slice(attachment *MTLRenderPassAttachmentDescriptor, slice u64) { msg_void_u(attachment, sel(&sel_setSlice_, "setSlice:"), slice) }

// Where multisample data is resolved to (with MTLStoreActionMultisampleResolve).
fn mtl_set_resolve_texture(attachment *MTLRenderPassAttachmentDescriptor, texture *MTLTexture) { msg_void_p(attachment, sel(&sel_setResolveTexture_, "setResolveTexture:"), texture) }

// What happens to the attachment's contents when the pass starts (MTLLoadAction*).
fn mtl_set_load_action(attachment *MTLRenderPassAttachmentDescriptor, action u64) { msg_void_u(attachment, sel(&sel_setLoadAction_, "setLoadAction:"), action) }

// What happens to the rendered contents when the pass ends (MTLStoreAction*).
fn mtl_set_store_action(attachment *MTLRenderPassAttachmentDescriptor, action u64) { msg_void_u(attachment, sel(&sel_setStoreAction_, "setStoreAction:"), action) }

// Colour used by MTLLoadActionClear. Colour attachments only.
fn mtl_set_clear_color(attachment *MTLRenderPassAttachmentDescriptor, color MTLClearColor) {
    msg_void_dddd(attachment, sel(&sel_setClearColor_, "setClearColor:"), color.red, color.green, color.blue, color.alpha)
}

// Depth used by MTLLoadActionClear. The depth attachment only.
fn mtl_set_clear_depth(attachment *MTLRenderPassAttachmentDescriptor, depth f64) { msg_void_d(attachment, sel(&sel_setClearDepth_, "setClearDepth:"), depth) }

// Stencil value used by MTLLoadActionClear. The stencil attachment only.
fn mtl_set_clear_stencil(attachment *MTLRenderPassAttachmentDescriptor, value u32) { msg_void_u(attachment, sel(&sel_setClearStencil_, "setClearStencil:"), u64(value)) }

// ---- MTLCommandQueue, MTLCommandBuffer
var sel_commandBuffer *u8
var sel_renderCommandEncoderWithDescriptor_ *u8
var sel_blitCommandEncoder *u8
var sel_computeCommandEncoder *u8
var sel_presentDrawable_ *u8
var sel_commit *u8
var sel_waitUntilCompleted *u8
var sel_waitUntilScheduled *u8
var sel_status *u8
var sel_error *u8

// A new command buffer (autoreleased); one per frame.
fn mtl_command_buffer(queue *MTLCommandQueue) *MTLCommandBuffer { msg_id(queue, sel(&sel_commandBuffer, "commandBuffer")) }

// Starts a render pass; the encoder (autoreleased) must be ended before the next one starts.
fn mtl_render_command_encoder_with_descriptor(buffer *MTLCommandBuffer, pass *MTLRenderPassDescriptor) *MTLRenderCommandEncoder {
    msg_id_p(buffer, sel(&sel_renderCommandEncoderWithDescriptor_, "renderCommandEncoderWithDescriptor:"), pass)
}

// An encoder for copies and mipmap generation (autoreleased).
fn mtl_blit_command_encoder(buffer *MTLCommandBuffer) *MTLBlitCommandEncoder { msg_id(buffer, sel(&sel_blitCommandEncoder, "blitCommandEncoder")) }

// An encoder for compute work (autoreleased).
fn mtl_compute_command_encoder(buffer *MTLCommandBuffer) *MTLComputeCommandEncoder { msg_id(buffer, sel(&sel_computeCommandEncoder, "computeCommandEncoder")) }

// Shows the drawable as soon as the command buffer has been scheduled.
fn mtl_present_drawable(buffer *MTLCommandBuffer, drawable *CAMetalDrawable) { msg_void_p(buffer, sel(&sel_presentDrawable_, "presentDrawable:"), drawable) }

// Submits the command buffer for execution.
fn mtl_commit(buffer *MTLCommandBuffer) { msg_void(buffer, sel(&sel_commit, "commit")) }

// Blocks until the GPU has finished executing the command buffer.
fn mtl_wait_until_completed(buffer *MTLCommandBuffer) { msg_void(buffer, sel(&sel_waitUntilCompleted, "waitUntilCompleted")) }

// Blocks until the command buffer has been scheduled.
fn mtl_wait_until_scheduled(buffer *MTLCommandBuffer) { msg_void(buffer, sel(&sel_waitUntilScheduled, "waitUntilScheduled")) }

// Where the command buffer is in its life (MTLCommandBufferStatus*).
fn mtl_status(buffer *MTLCommandBuffer) u64 { msg_u64(buffer, sel(&sel_status, "status")) }

// Why execution failed (status MTLCommandBufferStatusError), else nil.
fn mtl_error(buffer *MTLCommandBuffer) *NSError { msg_id(buffer, sel(&sel_error, "error")) }

// ---- encoders
var sel_endEncoding *u8
var sel_pushDebugGroup_ *u8
var sel_popDebugGroup *u8

// Finishes an encoder of any kind; required before committing or starting another encoder.
fn mtl_end_encoding[T](encoder *T) { msg_void(encoder, sel(&sel_endEncoding, "endEncoding")) }

// Opens a named group of commands for GPU debuggers (encoders and command buffers).
fn mtl_push_debug_group[T](encoder *T, name str) {
    text := ns_string(name)
    msg_void_p(encoder, sel(&sel_pushDebugGroup_, "pushDebugGroup:"), text)
    objc_release(text)
}

// Closes the innermost debug group.
fn mtl_pop_debug_group[T](encoder *T) { msg_void(encoder, sel(&sel_popDebugGroup, "popDebugGroup")) }

// ---- MTLRenderCommandEncoder
var sel_setRenderPipelineState_ *u8
var sel_setDepthStencilState_ *u8
var sel_setViewport_ *u8
var sel_setScissorRect_ *u8
var sel_setFrontFacingWinding_ *u8
var sel_setCullMode_ *u8
var sel_setTriangleFillMode_ *u8
var sel_setDepthBias_slopeScale_clamp_ *u8
var sel_setBlendColorRed_green_blue_alpha_ *u8
var sel_setStencilReferenceValue_ *u8
var sel_setVertexBuffer_offset_atIndex_ *u8
var sel_setVertexBufferOffset_atIndex_ *u8
var sel_setVertexBytes_length_atIndex_ *u8
var sel_setVertexTexture_atIndex_ *u8
var sel_setVertexSamplerState_atIndex_ *u8
var sel_setFragmentBuffer_offset_atIndex_ *u8
var sel_setFragmentBytes_length_atIndex_ *u8
var sel_setFragmentTexture_atIndex_ *u8
var sel_setFragmentSamplerState_atIndex_ *u8
var sel_drawPrimitives_vertexStart_vertexCount_ *u8
var sel_drawPrimitives_vertexStart_vertexCount_instanceCount_ *u8
var sel_drawIndexedPrimitives_indexCount_indexType_indexBuffer_indexBufferOffset_ *u8
var sel_drawIndexedPrimitives_indexCount_indexType_indexBuffer_indexBufferOffset_instanceCount_ *u8

// The pipeline used by the following draws.
fn mtl_set_render_pipeline_state(encoder *MTLRenderCommandEncoder, pipeline *MTLRenderPipelineState) { msg_void_p(encoder, sel(&sel_setRenderPipelineState_, "setRenderPipelineState:"), pipeline) }

// The depth/stencil test used by the following draws.
fn mtl_set_depth_stencil_state(encoder *MTLRenderCommandEncoder, state *MTLDepthStencilState) { msg_void_p(encoder, sel(&sel_setDepthStencilState_, "setDepthStencilState:"), state) }

// The rectangle of the render target that clip space maps to, and the depth range.
fn mtl_set_viewport(encoder *MTLRenderCommandEncoder, viewport MTLViewport) { msg_void_p(encoder, sel(&sel_setViewport_, "setViewport:"), &viewport) }

// Fragments outside this rectangle (in pixels) are discarded.
fn mtl_set_scissor_rect(encoder *MTLRenderCommandEncoder, rect MTLScissorRect) { msg_void_p(encoder, sel(&sel_setScissorRect_, "setScissorRect:"), &rect) }

// Which vertex order is front-facing (MTLWinding*; the default is clockwise).
fn mtl_set_front_facing_winding(encoder *MTLRenderCommandEncoder, winding u64) { msg_void_u(encoder, sel(&sel_setFrontFacingWinding_, "setFrontFacingWinding:"), winding) }

// Which faces are discarded (MTLCullMode*).
fn mtl_set_cull_mode(encoder *MTLRenderCommandEncoder, mode u64) { msg_void_u(encoder, sel(&sel_setCullMode_, "setCullMode:"), mode) }

// Filled triangles or outlines (MTLTriangleFillMode*).
fn mtl_set_triangle_fill_mode(encoder *MTLRenderCommandEncoder, mode u64) { msg_void_u(encoder, sel(&sel_setTriangleFillMode_, "setTriangleFillMode:"), mode) }

// Offsets fragment depth, for shadow maps and decals.
fn mtl_set_depth_bias(encoder *MTLRenderCommandEncoder, bias f32, slope_scale f32, clamp f32) {
    msg_void_fff(encoder, sel(&sel_setDepthBias_slopeScale_clamp_, "setDepthBias:slopeScale:clamp:"), bias, slope_scale, clamp)
}

// The constant colour of the MTLBlendFactorBlendColor / BlendAlpha factors.
fn mtl_set_blend_color(encoder *MTLRenderCommandEncoder, red f32, green f32, blue f32, alpha f32) {
    msg_void_ffff(encoder, sel(&sel_setBlendColorRed_green_blue_alpha_, "setBlendColorRed:green:blue:alpha:"), red, green, blue, alpha)
}

// The reference value of the stencil test.
fn mtl_set_stencil_reference_value(encoder *MTLRenderCommandEncoder, value u32) { msg_void_u(encoder, sel(&sel_setStencilReferenceValue_, "setStencilReferenceValue:"), u64(value)) }

// Binds a buffer (from `offset` bytes on) to vertex-stage buffer slot `index`.
fn mtl_set_vertex_buffer(encoder *MTLRenderCommandEncoder, buffer *MTLBuffer, offset u64, index u64) {
    msg_void_puu(encoder, sel(&sel_setVertexBuffer_offset_atIndex_, "setVertexBuffer:offset:atIndex:"), buffer, offset, index)
}

// Changes only the offset of the buffer already bound to vertex-stage slot `index`.
fn mtl_set_vertex_buffer_offset(encoder *MTLRenderCommandEncoder, offset u64, index u64) {
    msg_void_uu(encoder, sel(&sel_setVertexBufferOffset_atIndex_, "setVertexBufferOffset:atIndex:"), offset, index)
}

// Copies up to 4 KB of data (uniforms) into a temporary buffer bound to vertex-stage slot `index`.
fn mtl_set_vertex_bytes(encoder *MTLRenderCommandEncoder, bytes *u8, length u64, index u64) {
    msg_void_puu(encoder, sel(&sel_setVertexBytes_length_atIndex_, "setVertexBytes:length:atIndex:"), bytes, length, index)
}

// Binds a texture to vertex-stage texture slot `index`.
fn mtl_set_vertex_texture(encoder *MTLRenderCommandEncoder, texture *MTLTexture, index u64) { msg_void_pu(encoder, sel(&sel_setVertexTexture_atIndex_, "setVertexTexture:atIndex:"), texture, index) }

// Binds a sampler to vertex-stage sampler slot `index`.
fn mtl_set_vertex_sampler_state(encoder *MTLRenderCommandEncoder, sampler *MTLSamplerState, index u64) { msg_void_pu(encoder, sel(&sel_setVertexSamplerState_atIndex_, "setVertexSamplerState:atIndex:"), sampler, index) }

// Binds a buffer (from `offset` bytes on) to fragment-stage buffer slot `index`.
fn mtl_set_fragment_buffer(encoder *MTLRenderCommandEncoder, buffer *MTLBuffer, offset u64, index u64) {
    msg_void_puu(encoder, sel(&sel_setFragmentBuffer_offset_atIndex_, "setFragmentBuffer:offset:atIndex:"), buffer, offset, index)
}

// Copies up to 4 KB of data (uniforms) into a temporary buffer bound to fragment-stage slot `index`.
fn mtl_set_fragment_bytes(encoder *MTLRenderCommandEncoder, bytes *u8, length u64, index u64) {
    msg_void_puu(encoder, sel(&sel_setFragmentBytes_length_atIndex_, "setFragmentBytes:length:atIndex:"), bytes, length, index)
}

// Binds a texture to fragment-stage texture slot `index`.
fn mtl_set_fragment_texture(encoder *MTLRenderCommandEncoder, texture *MTLTexture, index u64) { msg_void_pu(encoder, sel(&sel_setFragmentTexture_atIndex_, "setFragmentTexture:atIndex:"), texture, index) }

// Binds a sampler to fragment-stage sampler slot `index`.
fn mtl_set_fragment_sampler_state(encoder *MTLRenderCommandEncoder, sampler *MTLSamplerState, index u64) { msg_void_pu(encoder, sel(&sel_setFragmentSamplerState_atIndex_, "setFragmentSamplerState:atIndex:"), sampler, index) }

// Draws `vertex_count` vertices starting at `vertex_start` (MTLPrimitiveType*).
fn mtl_draw_primitives(encoder *MTLRenderCommandEncoder, kind u64, vertex_start u64, vertex_count u64) {
    msg_void_uuu(encoder, sel(&sel_drawPrimitives_vertexStart_vertexCount_, "drawPrimitives:vertexStart:vertexCount:"), kind, vertex_start, vertex_count)
}

// Draws `instance_count` instances of a vertex range.
fn mtl_draw_primitives(encoder *MTLRenderCommandEncoder, kind u64, vertex_start u64, vertex_count u64, instance_count u64) {
    msg_void_uuuu(encoder, sel(&sel_drawPrimitives_vertexStart_vertexCount_instanceCount_, "drawPrimitives:vertexStart:vertexCount:instanceCount:"), kind, vertex_start, vertex_count, instance_count)
}

// Draws `index_count` indices read from `index_buffer` at `index_buffer_offset` bytes (MTLIndexType*).
fn mtl_draw_indexed_primitives(encoder *MTLRenderCommandEncoder, kind u64, index_count u64, index_type u64, index_buffer *MTLBuffer, index_buffer_offset u64) {
    msg_void_uuupu(encoder, sel(&sel_drawIndexedPrimitives_indexCount_indexType_indexBuffer_indexBufferOffset_, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:"),
        kind, index_count, index_type, index_buffer, index_buffer_offset)
}

// Draws `instance_count` instances of an indexed range.
fn mtl_draw_indexed_primitives(encoder *MTLRenderCommandEncoder, kind u64, index_count u64, index_type u64, index_buffer *MTLBuffer, index_buffer_offset u64, instance_count u64) {
    msg_void_uuupuu(encoder, sel(&sel_drawIndexedPrimitives_indexCount_indexType_indexBuffer_indexBufferOffset_instanceCount_, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:"),
        kind, index_count, index_type, index_buffer, index_buffer_offset, instance_count)
}

// ---- MTLBlitCommandEncoder
var sel_copyFromBuffer_sourceOffset_toBuffer_destinationOffset_size_ *u8
var sel_copyFromTexture_sourceSlice_sourceLevel_sourceOrigin_sourceSize_toTexture_destinationSlice_destinationLevel_destinationOrigin_ *u8
var sel_generateMipmapsForTexture_ *u8

// Copies `size` bytes between buffers on the GPU.
fn mtl_copy_from_buffer(encoder *MTLBlitCommandEncoder, source *MTLBuffer, source_offset u64, destination *MTLBuffer, destination_offset u64, size u64) {
    msg_void_pupuu(encoder, sel(&sel_copyFromBuffer_sourceOffset_toBuffer_destinationOffset_size_, "copyFromBuffer:sourceOffset:toBuffer:destinationOffset:size:"),
        source, source_offset, destination, destination_offset, size)
}

// Copies a region of one slice and mip level of a texture into another texture.
fn mtl_copy_from_texture(encoder *MTLBlitCommandEncoder, source *MTLTexture, source_slice u64, source_level u64, source_origin MTLOrigin, source_size MTLSize,
    destination *MTLTexture, destination_slice u64, destination_level u64, destination_origin MTLOrigin) {
    msg_void_puupppuup(encoder, sel(&sel_copyFromTexture_sourceSlice_sourceLevel_sourceOrigin_sourceSize_toTexture_destinationSlice_destinationLevel_destinationOrigin_,
        "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:"),
        source, source_slice, source_level, &source_origin, &source_size, destination, destination_slice, destination_level, &destination_origin)
}

// Fills every mip level below the base level by downsampling.
fn mtl_generate_mipmaps_for_texture(encoder *MTLBlitCommandEncoder, texture *MTLTexture) { msg_void_p(encoder, sel(&sel_generateMipmapsForTexture_, "generateMipmapsForTexture:"), texture) }

// ---- MTLComputeCommandEncoder
var sel_setComputePipelineState_ *u8
var sel_setBuffer_offset_atIndex_ *u8
var sel_setTexture_atIndex_ *u8
var sel_setBytes_length_atIndex_ *u8
var sel_dispatchThreadgroups_threadsPerThreadgroup_ *u8

// The kernel run by the following dispatches.
fn mtl_set_compute_pipeline_state(encoder *MTLComputeCommandEncoder, pipeline *MTLComputePipelineState) { msg_void_p(encoder, sel(&sel_setComputePipelineState_, "setComputePipelineState:"), pipeline) }

// Binds a buffer (from `offset` bytes on) to buffer slot `index` of the kernel.
fn mtl_set_buffer(encoder *MTLComputeCommandEncoder, buffer *MTLBuffer, offset u64, index u64) { msg_void_puu(encoder, sel(&sel_setBuffer_offset_atIndex_, "setBuffer:offset:atIndex:"), buffer, offset, index) }

// Binds a texture to texture slot `index` of the kernel.
fn mtl_set_texture(encoder *MTLComputeCommandEncoder, texture *MTLTexture, index u64) { msg_void_pu(encoder, sel(&sel_setTexture_atIndex_, "setTexture:atIndex:"), texture, index) }

// Copies up to 4 KB of data into a temporary buffer bound to buffer slot `index` of the kernel.
fn mtl_set_bytes(encoder *MTLComputeCommandEncoder, bytes *u8, length u64, index u64) { msg_void_puu(encoder, sel(&sel_setBytes_length_atIndex_, "setBytes:length:atIndex:"), bytes, length, index) }

// Runs the kernel on a grid of thread groups, each of `threads_per_group` threads.
fn mtl_dispatch_threadgroups(encoder *MTLComputeCommandEncoder, groups MTLSize, threads_per_group MTLSize) {
    msg_void_pp(encoder, sel(&sel_dispatchThreadgroups_threadsPerThreadgroup_, "dispatchThreadgroups:threadsPerThreadgroup:"), &groups, &threads_per_group)
}
