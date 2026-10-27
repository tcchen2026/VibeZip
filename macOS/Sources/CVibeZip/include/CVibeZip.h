#ifndef VIBEZIP_NATIVE_H
#define VIBEZIP_NATIVE_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct VZLibrary VZLibrary;
typedef struct VZArchive VZArchive;
enum { VZ_OK = 0, VZ_ERROR = 1, VZ_CANCELLED = 2, VZ_PASSWORD = 3,
       VZ_UNSUPPORTED = 4, VZ_DATA_ERROR = 5, VZ_LIMIT = 6, VZ_PARENT_PASSWORD = 7, VZ_ACCESS = 8 };
enum { VZ_OPEN = 0, VZ_EXTRACT = 1, VZ_TEST = 2, VZ_UPDATE = 3, VZ_HASH = 4 };
typedef struct { int32_t code; int32_t detail; char message[1024]; } VZError;

/* Callbacks and their context must remain valid until the synchronous call returns.
   Callback calls are serialized. Return nonzero from cancelled() to abort.
   password() returns 1 and a NUL-terminated UTF-8 password, 0 if unavailable,
   or -1 if the user cancelled. Passwords never enter command arguments or logs. */
typedef struct {
    void *context;
    int32_t (*cancelled)(void *);
    void (*progress)(void *, int32_t phase, uint64_t completed, uint64_t total, const char *path);
    int32_t (*password)(void *, char *buffer, size_t capacity);
    /* Receives a bounded sample of unmarked ZIP names. Return a Windows code
       page, or 0 for the ZIP standard's CP437 fallback. No data leaves the app. */
    uint32_t (*filename_code_page)(void *, const uint8_t *bytes, size_t size);
} VZCallbacks;

typedef struct {
    uint32_t index;
    char *path;
    char *method;
    uint64_t size;
    uint64_t packed_size;
    int64_t modified_ns;
    uint32_t crc;
    uint32_t mode;
    uint8_t has_size, has_packed_size, has_modified, has_crc;
    uint8_t is_directory, is_link, is_encrypted, reserved;
} VZEntry;
typedef struct {
    char *format;
    uint32_t entry_count;
    uint8_t can_update, multi_volume, encrypted_headers, direct_stream;
    uint64_t bytes_read;
} VZArchiveInfo;
typedef struct { uint32_t index; const char *destination; } VZExtractItem;
/* existing_index == UINT32_MAX means a new item. A null source retains existing
   data; a non-null path changes properties; a source streams new file contents. */
typedef struct {
    uint32_t existing_index;
    const char *path;
    const char *source;
    uint64_t size;
    int64_t modified_ns;
    uint32_t mode;
    uint8_t is_directory;
} VZUpdateItem;
typedef struct {
    const char *format;
    const char *method;
    uint64_t dictionary_bytes;
    uint64_t volume_bytes;
    int32_t level;          /* -1 keeps default properties for an existing archive. */
    int32_t threads;        /* 0 uses upstream defaults. */
    int32_t solid;          /* -1 keeps the handler default. */
    int32_t encrypt_headers; /* -1 preserves the existing setting. */
    int32_t zip_aes;        /* -1 preserves the existing method. */
} VZOptions;

int32_t vz_library_open(const char *path, VZLibrary **result, VZError *error);
void vz_library_close(VZLibrary *library);
char *vz_library_formats(VZLibrary *library);
void vz_string_free(char *string);
int32_t vz_archive_open(VZLibrary *, const char *path, const VZCallbacks *, VZArchive **, VZError *);
/* A direct stream holds the parent session alive. Otherwise scratch_path is a
   caller-owned, unique file in a private directory; output is limited while writing. */
int32_t vz_archive_open_nested(VZArchive *, uint32_t index, const char *scratch_path,
    uint64_t byte_limit, const VZCallbacks *parent_callbacks, const VZCallbacks *child_callbacks, VZArchive **, VZError *);
void vz_archive_close(VZArchive *);
int32_t vz_archive_info(VZArchive *, VZArchiveInfo *, VZError *);
void vz_archive_info_free(VZArchiveInfo *);
int32_t vz_archive_entry(VZArchive *, uint32_t index, VZEntry *, VZError *);
void vz_entry_free(VZEntry *);
int32_t vz_archive_extract(VZArchive *, const VZExtractItem *, uint32_t count,
    int32_t test_only, uint64_t byte_limit, const VZCallbacks *, VZError *);
int32_t vz_archive_rewrite(VZLibrary *, VZArchive *existing, const char *output,
    const VZUpdateItem *, uint32_t count, const VZOptions *, const VZCallbacks *, VZError *);
int32_t vz_library_hash(VZLibrary *, const char *algorithm, const char *path,
    const VZCallbacks *, char **digest, VZError *);

#ifdef __cplusplus
}
#endif
#endif
