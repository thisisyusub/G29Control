// G29 Control telemetry plugin for Euro Truck Simulator 2 / American Truck Simulator (macOS).
//
// The Mac versions of the games can't drive force feedback, but they load SCS telemetry
// plugins from "<game>.app/Contents/MacOS/plugins". This plugin sends the truck's state
// (speed, acceleration, suspension…) once per frame over UDP to 127.0.0.1:39229, where
// G29 Control turns it into forces for the wheel.
//
// The SCS SDK types below are the subset this plugin needs, laid out as in the official
// SCS Telemetry SDK headers (scssdk.h, scssdk_value.h, scssdk_telemetry*.h).
//
// Build: see build.sh

#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>

// MARK: - SCS SDK subset

typedef uint8_t scs_u8_t;
typedef uint32_t scs_u32_t;
typedef int32_t scs_s32_t;
typedef uint64_t scs_u64_t;
typedef float scs_float_t;
typedef double scs_double_t;
typedef const char *scs_string_t;
typedef void *scs_context_t;
typedef scs_s32_t scs_result_t;
typedef scs_u32_t scs_event_t;
typedef scs_u32_t scs_value_type_t;
typedef scs_s32_t scs_log_type_t;

#define SCS_RESULT_ok 0
#define SCS_RESULT_unsupported (-1)
#define SCS_U32_NIL ((scs_u32_t)-1)
#define SCS_MAKE_VERSION(major, minor) (((major) << 16) | (minor))
#define SCS_TELEMETRY_VERSION_1_00 SCS_MAKE_VERSION(1, 0)

#define SCS_TELEMETRY_EVENT_frame_start 1
#define SCS_TELEMETRY_EVENT_frame_end 2
#define SCS_TELEMETRY_EVENT_paused 3
#define SCS_TELEMETRY_EVENT_started 4

#define SCS_VALUE_TYPE_bool 1
#define SCS_VALUE_TYPE_float 5
#define SCS_VALUE_TYPE_fvector 7

#define SCS_TELEMETRY_CHANNEL_FLAG_none 0
#define SCS_LOG_TYPE_message 0
#define SCS_LOG_TYPE_error 2

typedef struct { scs_u8_t value; } scs_value_bool_t;
typedef struct { scs_float_t value; } scs_value_float_t;
typedef struct { scs_float_t x, y, z; } scs_value_fvector_t;

typedef struct {
    scs_value_type_t type;
    scs_u8_t _padding[4];
    union {
        scs_value_bool_t value_bool;
        scs_value_float_t value_float;
        scs_value_fvector_t value_fvector;
        scs_u8_t _largest[40];   // dplacement, the biggest SDK value type
    };
} scs_value_t;

typedef struct {
    scs_u32_t flags;
    scs_u8_t _padding[4];
    scs_u64_t render_time;
    scs_u64_t simulation_time;
    scs_u64_t paused_simulation_time;
} scs_telemetry_frame_start_t;

typedef void (*scs_log_t)(const scs_log_type_t type, const scs_string_t message);
typedef void (*scs_telemetry_event_callback_t)(const scs_event_t event, const void *const event_info,
                                               const scs_context_t context);
typedef void (*scs_telemetry_channel_callback_t)(const scs_string_t name, const scs_u32_t index,
                                                 const scs_value_t *const value, const scs_context_t context);
typedef scs_result_t (*scs_telemetry_register_for_event_t)(const scs_event_t event,
                                                           const scs_telemetry_event_callback_t callback,
                                                           const scs_context_t context);
typedef scs_result_t (*scs_telemetry_unregister_from_event_t)(const scs_event_t event);
typedef scs_result_t (*scs_telemetry_register_for_channel_t)(const scs_string_t name, const scs_u32_t index,
                                                             const scs_value_type_t type, const scs_u32_t flags,
                                                             const scs_telemetry_channel_callback_t callback,
                                                             const scs_context_t context);
typedef scs_result_t (*scs_telemetry_unregister_from_channel_t)(const scs_string_t name, const scs_u32_t index,
                                                                const scs_value_type_t type);

typedef struct {
    scs_string_t game_name;
    scs_string_t game_id;
    scs_u32_t game_version;
    scs_u32_t _padding;   // 64-bit builds
    scs_log_t log;
} scs_sdk_init_params_v100_t;

typedef struct {
    scs_sdk_init_params_v100_t common;
    scs_telemetry_register_for_event_t register_for_event;
    scs_telemetry_unregister_from_event_t unregister_from_event;
    scs_telemetry_register_for_channel_t register_for_channel;
    scs_telemetry_unregister_from_channel_t unregister_from_channel;
} scs_telemetry_init_params_v100_t;

// MARK: - Packet sent to G29 Control (keep in sync with ForceFeedback.parse in the app)

#define G29_PORT 39229
#define G29_MAGIC 0x54393247u   // "G29T"
#define G29_VERSION 1
#define G29_WHEELS 4

enum { G29_PAUSED = 1, G29_ENGINE_ON = 2, G29_PARKING_BRAKE = 4 };

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t flags;
    uint32_t game;              // 1 = ETS2, 2 = ATS
    uint64_t simulation_time;   // µs
    float speed;                // m/s, negative when reversing
    float accel[3];             // m/s², truck space: x right, y up, z backward
    float steering;             // truck.effective.steering, -1…1
    float rpm;
    float deflection[G29_WHEELS];   // suspension deflection, m (wheels 0/1 = front axle)
} g29_packet_t;

_Static_assert(sizeof(g29_packet_t) == 64, "packet layout changed");

static g29_packet_t packet;
static int sock = -1;
static struct sockaddr_in target;

// MARK: - Callbacks

static void on_float(const scs_string_t name, const scs_u32_t index, const scs_value_t *const value,
                     const scs_context_t context) {
    (void)name; (void)index;
    if (value && value->type == SCS_VALUE_TYPE_float) *(float *)context = value->value_float.value;
}

static void on_fvector(const scs_string_t name, const scs_u32_t index, const scs_value_t *const value,
                       const scs_context_t context) {
    (void)name; (void)index;
    if (!value || value->type != SCS_VALUE_TYPE_fvector) return;
    float *v = (float *)context;
    v[0] = value->value_fvector.x;
    v[1] = value->value_fvector.y;
    v[2] = value->value_fvector.z;
}

static void on_bool(const scs_string_t name, const scs_u32_t index, const scs_value_t *const value,
                    const scs_context_t context) {
    (void)name; (void)index;
    if (!value || value->type != SCS_VALUE_TYPE_bool) return;
    uint32_t bit = (uint32_t)(uintptr_t)context;
    if (value->value_bool.value) packet.flags |= bit; else packet.flags &= ~bit;
}

static void on_event(const scs_event_t event, const void *const event_info, const scs_context_t context) {
    (void)context;
    switch (event) {
    case SCS_TELEMETRY_EVENT_frame_start:
        if (event_info) packet.simulation_time = ((const scs_telemetry_frame_start_t *)event_info)->simulation_time;
        break;
    case SCS_TELEMETRY_EVENT_frame_end:
        if (sock >= 0) {
            sendto(sock, &packet, sizeof packet, 0, (const struct sockaddr *)&target, sizeof target);
        }
        break;
    case SCS_TELEMETRY_EVENT_paused:
        packet.flags |= G29_PAUSED;
        break;
    case SCS_TELEMETRY_EVENT_started:
        packet.flags &= ~G29_PAUSED;
        break;
    }
}

// MARK: - Entry points

__attribute__((visibility("default")))
scs_result_t scs_telemetry_init(const scs_u32_t version, const scs_telemetry_init_params_v100_t *const params) {
    if (version < SCS_TELEMETRY_VERSION_1_00 || !params) return SCS_RESULT_unsupported;
    const scs_telemetry_init_params_v100_t *p = params;

    memset(&packet, 0, sizeof packet);
    packet.magic = G29_MAGIC;
    packet.version = G29_VERSION;
    packet.flags = G29_PAUSED;   // the game starts paused and sends "started" when driving begins
    packet.game = (p->common.game_id && strcmp(p->common.game_id, "ats") == 0) ? 2 : 1;

    sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        p->common.log(SCS_LOG_TYPE_error, "G29 Control: could not create a UDP socket");
        return SCS_RESULT_unsupported;
    }
    memset(&target, 0, sizeof target);
    target.sin_family = AF_INET;
    target.sin_port = htons(G29_PORT);
    target.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    p->register_for_event(SCS_TELEMETRY_EVENT_frame_start, on_event, NULL);
    p->register_for_event(SCS_TELEMETRY_EVENT_frame_end, on_event, NULL);
    p->register_for_event(SCS_TELEMETRY_EVENT_paused, on_event, NULL);
    p->register_for_event(SCS_TELEMETRY_EVENT_started, on_event, NULL);

    const scs_u32_t none = SCS_TELEMETRY_CHANNEL_FLAG_none;
    p->register_for_channel("truck.speed", SCS_U32_NIL, SCS_VALUE_TYPE_float, none, on_float, &packet.speed);
    p->register_for_channel("truck.local.acceleration.linear", SCS_U32_NIL, SCS_VALUE_TYPE_fvector, none,
                            on_fvector, packet.accel);
    p->register_for_channel("truck.effective.steering", SCS_U32_NIL, SCS_VALUE_TYPE_float, none, on_float,
                            &packet.steering);
    p->register_for_channel("truck.engine.rpm", SCS_U32_NIL, SCS_VALUE_TYPE_float, none, on_float, &packet.rpm);
    p->register_for_channel("truck.engine.enabled", SCS_U32_NIL, SCS_VALUE_TYPE_bool, none, on_bool,
                            (scs_context_t)(uintptr_t)G29_ENGINE_ON);
    p->register_for_channel("truck.parking_brake", SCS_U32_NIL, SCS_VALUE_TYPE_bool, none, on_bool,
                            (scs_context_t)(uintptr_t)G29_PARKING_BRAKE);
    for (scs_u32_t i = 0; i < G29_WHEELS; i++) {
        p->register_for_channel("truck.wheel.susp.deflection", i, SCS_VALUE_TYPE_float, none, on_float,
                                &packet.deflection[i]);
    }

    p->common.log(SCS_LOG_TYPE_message, "G29 Control: sending telemetry to 127.0.0.1:39229 for force feedback");
    return SCS_RESULT_ok;
}

__attribute__((visibility("default")))
void scs_telemetry_shutdown(void) {
    if (sock >= 0) close(sock);
    sock = -1;
}
