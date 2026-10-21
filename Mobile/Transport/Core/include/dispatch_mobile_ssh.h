/*
 * dispatch_mobile_ssh: the iPhone SSH engine (russh) behind a C ABI, wrapped by the MobileTransport Swift
 * package. Hand-written; src/ffi.rs implements exactly these declarations.
 *
 * Threading: every callback runs on an engine thread. Callbacks must not block for long; questions
 * (host key, prompts, signatures) are answered later through their dms_reply.
 *
 * Contexts: every operation takes a context pointer that is passed back to its callbacks, and each
 * operation documents its last callback, after which that context is never used again.
 *
 * Strings passed to callbacks are valid only during the call. Strings returned to the caller are freed
 * with dms_string_free.
 */
#ifndef DISPATCH_MOBILE_SSH_H
#define DISPATCH_MOBILE_SSH_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Result codes. */
#define DMS_OK 0
#define DMS_AUTH_FAILED 1           /* the server refused this credential; others may still work */
#define DMS_NETWORK (-1)            /* TCP or socket failure */
#define DMS_TIMEOUT (-2)            /* handshake deadline or keepalive timeout */
#define DMS_HOST_KEY_REJECTED (-3)  /* the host key callback answered false */
#define DMS_PROTOCOL (-4)
#define DMS_INVALID_KEY (-5)
#define DMS_WRONG_PASSPHRASE (-6)
#define DMS_CANCELLED (-7)          /* a reply was dms_reply_cancel */
#define DMS_UNSUPPORTED (-8)
#define DMS_CLOSED (-9)             /* the connection is closed */
#define DMS_REFUSED (-10)           /* the server refused the channel request */
#define DMS_HOST_NOT_FOUND (-11)    /* name resolution found no address */
#define DMS_CONNECTION_REFUSED (-12) /* nothing accepted the TCP connection on the port */
#define DMS_UNREACHABLE (-13)       /* no route to the host (or Local Network access denied) */
#define DMS_NO_ANSWER (-14)         /* the host did not answer the TCP connection in time */

/* Authentication methods (remaining_methods bits). */
#define DMS_METHOD_PASSWORD 1u
#define DMS_METHOD_PUBLICKEY 2u
#define DMS_METHOD_KEYBOARD_INTERACTIVE 4u
#define DMS_METHOD_HOSTBASED 8u

/* How a command ended (dms_exited_fn kind). */
#define DMS_EXIT_STATUS 0
#define DMS_EXIT_SIGNAL 1
#define DMS_EXIT_LOST 2

typedef struct dms_session dms_session;
typedef struct dms_key dms_key;
/* A one-shot answer slot. Answer each exactly once with one dms_reply_* call (any thread, any time). */
typedef struct dms_reply dms_reply;

typedef struct dms_host_key {
    const char *algorithm;   /* "ssh-ed25519", "ecdsa-sha2-nistp256", "rsa-sha2-512", … */
    const uint8_t *blob;     /* the SSH public key blob */
    size_t blob_length;
    const char *fingerprint; /* "SHA256:<unpadded base64>", as ssh-keygen -lf prints it */
    const char *openssh;     /* "<type> <base64>" */
} dms_host_key;

typedef struct dms_prompt {
    const char *text;
    bool echo;
} dms_prompt;

typedef struct dms_connect_options {
    const char *host;
    uint16_t port;
    uint32_t timeout_ms;            /* handshake deadline, excluding the host key decision */
    uint32_t keepalive_interval_ms; /* keepalive after this much silence (0: none) */
    uint32_t keepalive_max;         /* unanswered keepalives before the connection counts as dead */
} dms_connect_options;

/* Answer with dms_reply_bool(reply, trusted). */
typedef void (*dms_host_key_fn)(void *context, const dms_host_key *key, dms_reply *reply);
/* The connection ended. Called once per connected session; the last call for the session context. */
typedef void (*dms_disconnected_fn)(void *context, int32_t code, const char *message);

typedef struct dms_session_callbacks {
    void *context;
    dms_host_key_fn host_key;
    dms_disconnected_fn disconnected;
} dms_session_callbacks;

/* session is NULL unless code is DMS_OK. */
typedef void (*dms_connected_fn)(void *context, dms_session *session, int32_t code, const char *message);
typedef void (*dms_auth_fn)(void *context, int32_t code, uint32_t remaining_methods, bool partial, const char *message);
/* Answer with dms_reply_strings (one response per prompt) or dms_reply_cancel. */
typedef void (*dms_prompt_fn)(void *context, const char *name, const char *instruction, const dms_prompt *prompts,
                              size_t count, dms_reply *reply);
/* Answer with dms_reply_bytes(raw signature: Ed25519 64 bytes; ECDSA r||s, fixed width) or dms_reply_cancel. */
typedef void (*dms_sign_fn)(void *context, const uint8_t *data, size_t length, dms_reply *reply);
/* fd is the caller's end of a socketpair (stdin writes, stdout reads), or -1 with an error code. */
typedef void (*dms_exec_started_fn)(void *context, int32_t fd, int32_t code, const char *message);
typedef void (*dms_stderr_fn)(void *context, const uint8_t *bytes, size_t length);
/* The last call for an exec context. status is meaningful for DMS_EXIT_STATUS, signal for DMS_EXIT_SIGNAL. */
typedef void (*dms_exited_fn)(void *context, int32_t kind, uint32_t status, const char *signal);

const char *dms_version(void);

/*
 * Connects and verifies the host key (callbacks.host_key). `connected` runs exactly once and is the last call
 * for `context`. When it reports a failure, callbacks.context is not used again either; on success,
 * callbacks.disconnected runs exactly once when the connection ends (lost, keepalive timeout, closed).
 */
void dms_connect(const dms_connect_options *options, dms_session_callbacks callbacks, void *context,
                 dms_connected_fn connected);
/* Disconnects; callbacks.disconnected follows. */
void dms_session_close(dms_session *session);
/* Releases the handle (closing the connection if it is still open). */
void dms_session_free(dms_session *session);

/* Each runs `done` exactly once, as the last call for `context`. */
void dms_auth_password(dms_session *session, const char *user, const char *password, void *context, dms_auth_fn done);
void dms_auth_key(dms_session *session, const char *user, const dms_key *key, void *context, dms_auth_fn done);
void dms_auth_keyboard_interactive(dms_session *session, const char *user, void *context, dms_prompt_fn prompt,
                                   dms_auth_fn done);
/* Public key auth where the caller signs (Secure Enclave, Keychain keys): public_key is the SSH key blob. */
void dms_auth_signer(dms_session *session, const char *user, const uint8_t *public_key, size_t length, void *context,
                     dms_sign_fn sign, dms_auth_fn done);

/*
 * OpenSSH private key file (ED25519, ECDSA P-256/384/521, RSA; passphrase optional) or PEM/PKCS#8.
 * Returns NULL and sets *code and *message (free with dms_string_free) on failure. RSA keys sign
 * rsa-sha2-512 or rsa-sha2-256, never ssh-rsa.
 */
dms_key *dms_key_parse(const uint8_t *data, size_t length, const char *passphrase, int32_t *code, char **message);
/* Strings owned by the key. */
const char *dms_key_algorithm(const dms_key *key);
const char *dms_key_public_key(const dms_key *key);
const char *dms_key_fingerprint(const dms_key *key);
void dms_key_free(dms_key *key);

/*
 * Runs `command` on a new session channel. `started` runs once; on failure it is the last call. Otherwise
 * stderr chunks may follow, then `exited` exactly once. The fd belongs to the caller: shutdown(SHUT_WR) sends
 * EOF, the remote's EOF reads as end of file, close() abandons the command.
 */
void dms_exec(dms_session *session, const char *command, void *context, dms_exec_started_fn started,
              dms_stderr_fn stderr_chunk, dms_exited_fn exited);

void dms_reply_bool(dms_reply *reply, bool value);
void dms_reply_strings(dms_reply *reply, const char *const *strings, size_t count);
void dms_reply_bytes(dms_reply *reply, const uint8_t *bytes, size_t length);
void dms_reply_cancel(dms_reply *reply);

void dms_string_free(char *string);

#ifdef __cplusplus
}
#endif

#endif
