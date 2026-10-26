// mod_archive_extract (app/Madeira/ModArchive.h): unpack a mod archive with
// libarchive. Mods come from Windows, so names may use backslashes; every
// name is reduced to a plain relative path before anything is written, and
// anything that could leave the destination is skipped.

#include "ModArchive.h"

#include <archive.h>
#include <archive_entry.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void set_error(char *error, size_t size, const char *fmt, const char *detail)
{
    if (error && size) snprintf(error, size, fmt, detail ? detail : "");
}

/// "a\b/./c" -> "a/b/c" in `out`; 0 when the name is empty, absolute after
/// trimming, or has a ".." part.
static int clean_name(const char *name, char *out, size_t out_size)
{
    size_t n = 0;
    const char *p = name;
    while (*p) {
        while (*p == '/' || *p == '\\') p++;
        if (!*p) break;
        const char *start = p;
        while (*p && *p != '/' && *p != '\\') p++;
        size_t len = (size_t)(p - start);
        if (len == 1 && start[0] == '.') continue;
        if (len == 2 && start[0] == '.' && start[1] == '.') return 0;
        if (len == 2 && start[1] == ':') return 0;   /* "C:" drive prefix */
        if (n + len + 2 > out_size) return 0;
        if (n) out[n++] = '/';
        memcpy(out + n, start, len);
        n += len;
    }
    out[n] = 0;
    return n > 0;
}

/// mkdir -p for every folder above `path` (and `path` itself when `self`).
static int make_dirs(char *path, int self)
{
    for (char *p = path + 1; *p; p++) {
        if (*p != '/') continue;
        *p = 0;
        if (mkdir(path, 0755) != 0 && errno != EEXIST) { *p = '/'; return -1; }
        *p = '/';
    }
    if (self && mkdir(path, 0755) != 0 && errno != EEXIST) return -1;
    return 0;
}

int mod_archive_extract(const char *archive_path, const char *dest_dir,
                        mod_archive_progress_fn progress, void *context,
                        char *error, size_t error_size)
{
    struct archive *a = archive_read_new();
    archive_read_support_filter_all(a);
    archive_read_support_format_all(a);
    if (archive_read_open_filename(a, archive_path, 1 << 20) != ARCHIVE_OK) {
        set_error(error, error_size, "The archive could not be opened: %s", archive_error_string(a));
        archive_read_free(a);
        return 1;
    }

    const size_t buffer_size = 1 << 16;
    char *buffer = malloc(buffer_size);
    if (!buffer) {
        archive_read_free(a);
        set_error(error, error_size, "%s", "Out of memory.");
        return 3;
    }
    char dest[4096];
    snprintf(dest, sizeof(dest), "%s", dest_dir);
    make_dirs(dest, 1);

    int result = 0;
    int64_t files = 0, bytes = 0;
    char name[2048], target[4096 + 2048];
    struct archive_entry *entry;

    for (;;) {
        int r = archive_read_next_header(a, &entry);
        if (r == ARCHIVE_EOF) break;
        if (r == ARCHIVE_FATAL) {
            set_error(error, error_size, "The archive is damaged or uses a format that can't be read: %s",
                      archive_error_string(a));
            result = 1;
            break;
        }
        if (archive_entry_is_encrypted(entry)) {
            set_error(error, error_size, "%s", "The archive is password-protected.");
            result = 2;
            break;
        }
        const char *raw = archive_entry_pathname_utf8(entry);
        if (!raw) raw = archive_entry_pathname(entry);
        if (!raw || !clean_name(raw, name, sizeof(name))) continue;
        snprintf(target, sizeof(target), "%s/%s", dest, name);

        mode_t type = archive_entry_filetype(entry);
        if (type == AE_IFDIR) {
            make_dirs(target, 1);
            continue;
        }
        if (type != AE_IFREG) continue;   /* links, devices, fifos */

        if (make_dirs(target, 0) != 0) {
            set_error(error, error_size, "Could not create a folder for %s", name);
            result = 3;
            break;
        }
        int fd = open(target, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) {
            set_error(error, error_size, "Could not write %s", name);
            result = 3;
            break;
        }
        for (;;) {
            la_ssize_t got = archive_read_data(a, buffer, buffer_size);
            if (got == 0) break;
            if (got < 0) {
                set_error(error, error_size, "The archive could not be read: %s", archive_error_string(a));
                result = 1;
                break;
            }
            for (la_ssize_t off = 0; off < got;) {
                ssize_t w = write(fd, buffer + off, (size_t)(got - off));
                if (w < 0) {
                    if (errno == EINTR) continue;
                    set_error(error, error_size, "Could not write %s (is the device full?)", name);
                    result = 3;
                    break;
                }
                off += w;
            }
            if (result) break;
            bytes += got;
        }
        close(fd);
        if (result) break;
        files++;
        if (progress && progress(context, files, bytes)) {
            set_error(error, error_size, "%s", "Stopped.");
            result = 4;
            break;
        }
    }
    free(buffer);
    archive_read_free(a);
    return result;
}
